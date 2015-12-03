package GRNOC::TSDS::Aggregate::Daemon;

use strict;
use warnings;

use Moo;
use Types::Standard qw( Str Bool );
use Try::Tiny;

use GRNOC::Config;
use GRNOC::Log;

use Proc::Daemon;

use POSIX;
use Data::Dumper;

use MongoDB;

use Net::AMQP::RabbitMQ;
use JSON::XS;

use Redis;
use Redis::DistLock;

extends 'GRNOC::TSDS::Aggregate';

### private attributes ###

has required_fields => ( is => 'rwp', 
			 default => sub { {} });

has value_fields => ( is => 'rwp', 
		     default => sub { {} });

has identifiers => ( is => 'rwp',
		     default => sub { {} } );

has now => ( is => 'rwp',
	     default => 0 );

has mongo => ( is => 'rwp' );

has rabbit => ( is => 'rwp' );

has rabbit_queue => ( is => 'rwp' );

has locker => ( is => 'rwp' );

has locks => ( is => 'rwp',
	       default => sub { [] } );

### public methods ###

sub start {

    my ( $self ) = @_;

    log_info( 'Starting TSDS Aggregate daemon.' );

    if (! $self->config ){
        die "Unable to load config file";
    }

    log_debug( 'Setting up signal handlers.' );

    # need to daemonize
    if ( $self->daemonize ) {

        log_debug( 'Daemonizing.' );

        my $daemon = Proc::Daemon->new( pid_file => $self->config->get( '/config/pid-file' ) );

        my $pid = $daemon->Init();

        # in child/daemon process
        if ( $pid ){
            log_debug(" Forked child $pid, exiting process ");
            return;
        }

        log_debug( 'Created daemon process.' );
    }

    # dont need to daemonize
    else {

        log_debug( 'Running in foreground.' );
    }

    $self->_mongo_connect() or return;

    $self->_rabbit_connect() or return;

    $self->_redis_connect() or return;

    $self->_work_loop();

    return 1;
}

sub _work_loop {
    my ( $self ) = @_;

    log_debug("Entering main work loop");

    while (1){

        my $next_wake_time;
    
        $self->_set_now(time());

        # Find the databases that need workings
        my $dbs = $self->_get_aggregate_policies();

        if ((keys %$dbs) == 0){
            log_info("No aggregate policies to work on, sleeping for 60s...");
            sleep(60);
            next;
        }

        # For each of those databases, determine whether
        # it's time to do work yet or not
        foreach my $db_name (keys %$dbs){
            my $policies = $dbs->{$db_name};

	    my $next_run;

	    try {
		# Make sure we know the required fields for this database
		my $success = $self->_get_metadata($db_name);
		return if (! defined $success);
		
		$next_run = $self->_evaluate_policies($db_name, $policies);
		next if (! defined $next_run);
		
		log_debug("Next run is $next_run for $db_name");
	    }
	    catch {
		log_warn("Caught exception while processing $db_name: $_");
	    };

	    # Possibly redundant release in case an exception happened above, want
	    # to make sure we're not hanging on to things
	    $self->_release_locks();

	    next if (! defined $next_run);

	    # Figure out when the next time we need to look at this is.
	    # If it's closer than anything else, update our next wake 
	    # up time to that
	    $next_wake_time = $next_run if (! defined $next_wake_time || $next_run < $next_wake_time);	    
	}


	if (! defined $next_wake_time){
	    log_info("Unable to determine a next wake time, did exceptions happen? Sleeping for 60s and trying again");
	    $next_wake_time = time() + 60;
	}
       
        log_debug("Next wake time is $next_wake_time");


        # Sleep until the next time we've determined we need to do something
        my $delta = $next_wake_time - time;
        if ($delta > 0){
            log_info("Sleeping $delta seconds until next work");
            sleep($delta);
        }
        else {
            log_debug("Not sleeping since delta <= 0");
        }
    }
}

# Operate on all the aggregation policies for a given database
# and create any messages needed.
sub _evaluate_policies {
    my ( $self, $db_name, $policies ) = @_;

    # Make sure we get them in the ascending interval order
    # but descending eval position order so that in the event
    # of a time for interval we use the heaviest evaluated one
    @$policies = sort {$a->{'interval'} <=> $b->{'interval'}
		       ||
		       $b->{'eval_position'} <=> $a->{'eval_position'}} @$policies;
    
    # Keep track of the earliest we need to run next for this db
    my $lowest_next_run;

    # Iterate over each policy to figure out what needs doing if anything
    foreach my $policy (@$policies){	
	my $interval = $policy->{'interval'};
	my $name     = $policy->{'name'};
	my $last_run = $policy->{'last_run'} || 0;

	log_debug("Last run for $db_name $name was $last_run");

	my $next_run = $last_run + $interval;
	
	# If there's work to do, let's craft a work
	# order out to some worker and send it
	if ($next_run <= $self->now()){

	    # Get the set of measurements that apply to this policy
	    my $measurements = $self->_get_measurements($db_name, $policy);
	    next if (! $measurements);

	    # Find the previous policy that applied to this measurement so we know
	    # what dirty docs to check
	    # This will also omit any measurements that were already applied to a same
	    # interval but heavier weighted policy to avoid the redundancy. Later on we
	    # only care about what interval was picked, not why it was picked.
	    my $work_buckets = $self->_find_previous_policies(db           => $db_name,
							      current      => $policy,
							      policies     => $policies,
							      measurements => $measurements);


	    # Figure out from those measurements which have data that needs
	    # aggregation into this policy
	    foreach my $prev_interval (keys %$work_buckets){
		log_debug("Processing data from $prev_interval");

		my $interval_measurements = $work_buckets->{$prev_interval};

		my $dirty_docs = $self->_get_dirty_data($db_name, $prev_interval, $last_run, $interval_measurements);
		return if (! $dirty_docs);

		# Create and send out rabbit messages describing work that
		# needs doing
		my $result = $self->_generate_work(policy        => $policy,
						   db            => $db_name,
						   interval_from => $prev_interval,
						   interval_to   => $interval,
						   docs          => $dirty_docs,
						   measurements  => $interval_measurements);

		if (! defined $result){
		    log_warn("Error generating work for $db_name policy $name, skipping");
		    return;
		}		
	    }
	    
	    # Update the aggregate to show the last time we successfully 
	    # generated work for this
	    
	    # Floor the "now" to the interval to make a restart run pick a pretty
	    # last run time. This is still accurate since floored must be <= $now
	    my $floored = int($self->now() / $interval) * $interval;
	    $self->mongo->get_database($db_name)
		->get_collection("aggregate")
		->update({"name" => $name}, {'$set' => {"last_run" => $floored}});

	    # Since we ran, the next time we need to look is the next time this
	    # the next time its interval is coming around in the future
	    $next_run = $floored + $interval;
	}

	# Figure out the nearest next run time
	$lowest_next_run = $next_run if (! defined $lowest_next_run || $next_run < $lowest_next_run);
    }
    
    return $lowest_next_run;
}

# Returns an array of just the required field names for a given
# TSDS database
sub _get_metadata { 
    my ( $self, $db_name ) = @_;

    my $metadata;

    eval {
	$metadata = $self->mongo->get_database($db_name)->get_collection('metadata')->find_one();
    };
    if ($@){
	log_warn("Error getting metadata from mongo for $db_name: $@");
	return;
    }

    my @required;

    my $meta_fields = $metadata->{'meta_fields'};

    foreach my $field (keys %$meta_fields){
	next unless ($meta_fields->{$field}->{'required'});
	push(@required, $field);
    }

    my @values;

    foreach my $field (keys %{$metadata->{'values'}}){
	push(@values, $field);
    }

    # Remember these
    $self->required_fields->{$db_name} = \@required;
    $self->value_fields->{$db_name} = \@values;

    log_debug("Required fields for $db_name = " . Dumper(\@required));
    log_debug("Values for $db_name = " . Dumper(\@values));

    # Don't think this should ever be hit, but as a fail safe let's
    # make sure to check we found at least something because otherwise
    # sadness will ensue
    if (@required == 0 || @values == 0){
	log_warn("Unable to determine required meta fields and/or value field names for $db_name");
	return;
    }

    return 1;
}

sub _get_measurements {
    my ( $self, $db_name, $policy ) = @_;

    my $meta     = $policy->{'meta'};
    my $interval = $policy->{'interval'};
    my $name     = $policy->{'name'};

    my $obj;
    eval {
	$obj = JSON::XS::decode_json($meta);
    };
    if ($@){
	log_warn("Unable to decode \"$meta\" as JSON in $db_name policy $name: $@");
	return;
    }

    # Build up the query we need to aggregate
    my @agg;

    # Hm this isn't technically accurate, we might need to do multiple passes
    # once we find the data to figure out if the metadata at the time matched
    push(@agg, {'$match' => $obj});
    push(@agg, {'$group'  => {'_id'       => '$identifier',
			      'max_start' => {'$max' => '$start'}}});

    my $results;
    eval {
	$results = $self->mongo
	    ->get_database($db_name)
	    ->get_collection('measurements')
	    ->aggregate(\@agg);
    };
    if ($@){
	log_warn("Unable to fetch latest measurement entries for $db_name policy $name: $@");
	return;
    }

    my @ors;
    foreach my $res (@$results){
	push(@ors, {
	    'identifier' => $res->{'_id'},
	    'start'      => $res->{'max_start'}
	     });
    }

    my $fields = {'identifier' => 1, 'values' => 1, 'start' => 1};
    foreach my $req_field (@{$self->required_fields->{$db_name}}){
	$fields->{$req_field} = 1;
    }

    my $cursor;
    eval {
	$cursor = $self->mongo
	    ->get_database($db_name)
	    ->get_collection('measurements')
	    ->find({'$or' => \@ors})->fields($fields);
    };

    # Convert to a hash for easier lookup later
    my %lookup;
    while (my $doc = $cursor->next()){
	$lookup{$doc->{'identifier'}} = $doc;
    }

    # Remember these identifiers so that we can reference them later
    # when figuring out the nearest policy
    $self->identifiers->{$db_name . $name} = \%lookup;

    log_debug("Found " . scalar(keys %lookup) . " measurements for $db_name policy $name");

    return \%lookup;
}

# Given the set of measurements and all the policies,
# find the previous policy that applies to each measurement
sub _find_previous_policies {
    my ( $self, %args ) = @_;

    my $db_name        = $args{'db'};
    my $current_policy = $args{'current'};
    my $policies       = $args{'policies'};
    my $measurements   = $args{'measurements'};

    my %buckets;

    # Make sure we get in descending order, we want to find the highest
    # possible previous one
    my @sorted = sort {$b->{'interval'} <=> $a->{'interval'}
		       ||
		       $b->{'eval_position'} <=> $a->{'eval_position'}} @$policies;

    my $current_interval = $current_policy->{'interval'};

    my @possible_matches;

    # We're looking for a prior policy so the interval has to be smaller
    # or can be the same, in which case if we've already seen
    # the identifier in another policy with the same interval we can skip it
    # here since we have already aggregated it   
    foreach my $policy (@sorted){
	# skip ourselves
	next if ($current_policy->{'name'} eq $policy->{'name'});
	next if ($current_policy->{'interval'} > $current_interval);
	push(@possible_matches, $policy);
    }

    foreach my $identifier (keys %$measurements){

	# Keep track of what we're ultimately choosing for this
	# identifier
	my $chosen;

	# These will still be sorted by interval and eval position appropriately
	# so we want to see if any have matched this before
	my $already_done = 0;
	foreach my $match (@possible_matches){
	    # We can't use this as the previous policy if that policy didn't include this identifier
	    next unless (exists $self->identifiers->{$db_name . $match->{'name'}}->{$identifier});

	    # If this policy DID include the identifier, we have to see if it was the same interval
	    # or not. If it's the same interval, we don't need to re-aggregate this at all at this
	    # level since it would be redundant work.
	    if ($match->{'interval'} eq $current_interval){
		$already_done = 1;
	    }	   

	    $chosen = $match;
	    last;
	}

	# If we decided that we had already aggregated this measurement at this
	# interval, we don't need to do anything else here.
	next if ($already_done);

	# Use the chosen's interval if we can use a prior aggregation policy. If we can't
	# then default to interval of 1, or hi-res
	my $chosen_interval = defined $chosen ? $chosen->{'interval'} : 1;

	$buckets{$chosen_interval}{$identifier} = $measurements->{$identifier};
    }

    foreach my $interval (keys %buckets){
	log_debug("Building " . scalar(keys %{$buckets{$interval}}) . " measurements for interval $current_interval from interval $interval");
    }

    return \%buckets;
}

# Given a database name, an interval, and a timestamp it this figures out
# what data documents for that interval have been updated since the timestamp.
# This returns all those documents
sub _get_dirty_data {
    my ( $self, $db_name, $interval, $last_run, $measurements ) = @_;

    my @ids = keys %$measurements;

    my $query = {
	'updated'    => {'$gte' => $last_run},
	'identifier' => {'$in' => \@ids}
    };

    log_debug("Getting dirty docs since $last_run");

    my $col_name = "data";
    if ($interval && $interval > 1){
	$col_name = "data_$interval";
    }

    my $collection = $self->mongo->get_database($db_name)->get_collection($col_name);

    my $fields = {
	"updated_start" => 1,
	"updated_end"   => 1,
	"start"         => 1,
	"end"           => 1,
	"identifier"    => 1,
	"_id"           => 1
    };

    my $cursor;
    eval {
	$cursor = $collection->find($query)->fields($fields);
    };

    if ($@){
	log_warn("Unable to find dirty documents in $db_name at interval $interval: $@");
	return;
    }

    my @docs;

    while (my $doc = $cursor->next() ){
	push(@docs, $doc);	
    }

    log_debug("Found " . scalar(@docs) . " dirty docs, attempting to get locks");

    # This part is a bit strange. We have to do a first fetch to figure out
    # what all docs we're going to need to touch. Then we need to lock them
    # all through Redis so that another process doesn't touch them while
    # we're doing our thing. Then we need to fetch them again to ensure that
    # the version in memory is the same as the one on disk
    # We're also fetching them by _id the second time around to make sure
    # we're only getting exactly the ones we have already locked. Any others
    # will be picked up in a later run.
    my @internal_ids;
    my @locks;
    foreach my $doc (@docs){
	my $key  = $self->_get_cache_key($db_name, $col_name, $doc);
	my $lock = $self->locker->lock($key, 60);
	push(@internal_ids, $doc->{'_id'});
	push(@locks, $lock);
    }

    # Store all of the locks we need to release later
    $self->_set_locks(\@locks);

    # Now that they're all locked, fetch them again
    eval {	
	$cursor = $collection->find({_id => {'$in' => \@internal_ids}})->fields($fields);
    };
    if ($@){
	log_warn("Unable to find dirty documents on fetch 2: $@");
	return;
    }

    undef @docs;
    while (my $doc = $cursor->next()){
	push(@docs, $doc);
    }

    log_debug("Found " . scalar(@docs) . " final dirty docs");

    return \@docs;
}

# Formulate and send a message out to a worker
sub _generate_work {
    my ( $self, %args ) = @_;

    my $db             = $args{'db'};
    my $interval_from  = $args{'interval_from'};
    my $interval_to    = $args{'interval_to'};
    my $docs           = $args{'docs'};
    my $measurements   = $args{'measurements'};
    my $policy         = $args{'policy'};

    my @messages;

    # Go through each data document and create a message describing
    # the work needed for the doc.

    # We want to group all the interfaces with the same ceil/floor together
    # so that we can condense them into the same message and have them be
    # serviceable in the same query

    my %grouped;

    my @doc_ids;

    foreach my $doc (@$docs){
	my $updated_start = $doc->{'updated_start'};
	my $updated_end   = $doc->{'updated_end'};
	my $identifier    = $doc->{'identifier'};

	# We want to floor/ceil to find the actual timerange affected in the
	# interval in this doc. ie we might have only touched data within one
	# hour but it's going to impact that whole day. Any other measurements
	# impacted during that day can be grouped into the same query
	my $floor = int($updated_start / $interval_to) * $interval_to;
	my $ceil  = int(ceil($updated_end / $interval_to)) * $interval_to;

	push(@{$grouped{$floor}{$ceil}}, $doc);
	push(@doc_ids, $doc->{'_id'});
    }

    my @final_values;
    foreach my $value (@{$self->value_fields->{$db}}){
	my $attributes = {
	    name           => $value,
	    hist_res       => undef,
	    hist_min_width => undef
	};
	if (exists $policy->{'values'}{$value}){
	    $attributes->{'hist_res'}       = $policy->{'values'}{$value}{'hist_res'};
	    $attributes->{'hist_min_width'} = $policy->{'values'}{$value}{'hist_min_width'};
	}
	push(@final_values, $attributes);
    }

    # Now that we have grouped the messages based on their timeframes
    # we can actually ship them out to rabbit
    foreach my $start (keys %grouped){
	foreach my $end (keys %{$grouped{$start}}){

	    my $grouped_docs = $grouped{$start}{$end};

	    log_debug("Sending messages for $start - $end, interval_from = $interval_from interval_to = $interval_to, total grouped measurements = " . scalar(@$grouped_docs));

	    my $message = {            
		type           => $db,
		interval_from  => $interval_from,
		interval_to    => $interval_to,
		start          => $start,
		end            => $end,
		meta           => [],
		required_meta  => $self->required_fields->{$db},
		values         => \@final_values		
	    };

	    # Add the meta fields to our message identifying
	    # this measurement
	    foreach my $doc (@$grouped_docs){

		my $measurement = $measurements->{$doc->{'identifier'}};
		my @meas_values;
		my %meas_fields;

		# Add the min/max for values if present
		if (exists $measurement->{'values'}){
		    foreach my $value_name (keys %{$measurement->{'values'}}){
			push(@meas_values, {
			    'name' => $value_name,
			    'min'  => $measurement->{'values'}{$value_name}{'min'},
			    'max'  => $measurement->{'values'}{$value_name}{'max'}
			});
		    }
		}

		# Add the meta required fields
		foreach my $req_field (@{$self->required_fields->{$db}}){
		    $meas_fields{$req_field} = $measurement->{$req_field};
		}

		my $meta = {
		    values => \@meas_values,
		    fields => \%meas_fields
		};

		push(@{$message->{'meta'}}, $meta);

		# Avoid making messages too big, chunk them up
		if (@{$message->{'meta'}} >= 50){
		    $self->rabbit->publish(1, $self->rabbit_queue, encode_json([$message]), {'exchange' => ''});
		    $message->{'meta'} = [];
		}
	    }

	    # Any leftover tasks, send that too
	    if (@{$message->{'meta'}} > 0){
		$self->rabbit->publish(1, $self->rabbit_queue, encode_json([$message]), {'exchange' => ''});
	    }
	}    
    }

    # Now that we have generated all of the messages, we can go through and clear the flags 
    # on each of these data documents
    my $col_name = "data";
    if ($interval_from > 1){
	$col_name = "data_$interval_from";
    }   
    my $collection = $self->mongo->get_database($db)->get_collection($col_name);

    log_debug("Clearing updated flags for impacted docs in $db $col_name");

    eval {	
	$collection->update({_id => {'$in' => \@doc_ids}},
			    {'$unset' => {'updated'       => 1,
					  'updated_start' => 1,
					  'updated_end'   => 1}},
			    {multiple => 1});
    };
    if ($@){
	log_warn("Unable to clear updated flags on data docs: $@");
	return;
    }

    # We can go ahead and let go of all of our locks now
    $self->_release_locks();

    return 1;
}


sub _get_aggregate_policies {
    my ( $self ) = @_;

    my @db_names = $self->mongo->database_names;

    my %policies;

    foreach my $db_name (@db_names){

        my $cursor;
	my @docs;
        eval {
            $cursor = $self->mongo->get_database($db_name)->get_collection("aggregate")->find();
	    while (my $doc = $cursor->next()){

		if (! defined $doc->{'eval_position'} || ! defined $doc->{'interval'}){
		    log_warn("Skipping " . $doc->{'name'} . " due to missing eval position and/or interval");
		    next;
		}

		push(@docs, $doc);
	    }
        };
        if ($@){
            if ($@ !~ /not authorized/){
                log_warn("Error querying mongo: $@");
            }
            next;
        }

	if (! @docs){
	    log_debug("No aggregate policies found for database $db_name");
	    next;
	}

	$policies{$db_name} = \@docs;
    }

    log_debug("Found aggregate policies: " . Dumper(\%policies));

    return \%policies;
}


sub _mongo_connect {
    my ( $self ) = @_;

    my $mongo_host = $self->config->get( '/config/master/mongo/host' );
    my $mongo_port = $self->config->get( '/config/master/mongo/port' );
    my $user       = $self->config->get( '/config/master/mongo/username' );
    my $pass       = $self->config->get( '/config/master/mongo/password' );

    log_debug( "Connecting to MongoDB as $user:$pass on $mongo_host:$mongo_port." );

    my $mongo;
    eval {
        $mongo = MongoDB::MongoClient->new(
            host => "$mongo_host:$mongo_port",
            query_timeout => -1,
            username => $user,
            password => $pass
            );
    };
    if($@){
        log_warn("Could not connect to Mongo: $@");
        return;
    }

    log_debug("Connected");

    $self->_set_mongo( $mongo );
}


sub _rabbit_connect {
    my ( $self ) = @_;

    my $rabbit = Net::AMQP::RabbitMQ->new();   

    my $rabbit_host = $self->config->get( '/config/rabbit/host' );
    my $rabbit_port = $self->config->get( '/config/rabbit/port' );
    my $rabbit_queue = $self->config->get( '/config/rabbit/pending-queue' );

    log_debug("Connecting to RabbitMQ on $rabbit_host:$rabbit_port with queue $rabbit_queue");

    my $rabbit_args = {'port' => $rabbit_port};

    eval {
        $rabbit->connect( $rabbit_host, $rabbit_args );
        $rabbit->channel_open( 1 );
        $rabbit->queue_declare( 1, $rabbit_queue, {'auto_delete' => 0} );
    };
    if ($@){
        log_warn("Unable to connect to RabbitMQ: $@");
        return;
    }

    $self->_set_rabbit_queue($rabbit_queue);
    $self->_set_rabbit($rabbit);

    log_debug("Connected");

    return 1;
}

sub _redis_connect {
    my ( $self ) = @_;

    my $redis_host = $self->config->get( '/config/master/redis/host' );
    my $redis_port = $self->config->get( '/config/master/redis/port' );

    log_debug("Connecting to redis on $redis_host:$redis_port");

    my $redis = Redis->new( server => "$redis_host:$redis_port" );

    my $locker = Redis::DistLock->new( servers => [$redis],
                                       retry_count => 10 );

    $self->_set_locker( $locker );

    log_debug("Connected");

    return 1;
}

# Given a database name, collection name, and a data document
# generates the Redis lock cache key in the same manner as the writer
# process to help them coordinate
sub _get_cache_key {
    my ( $self, $db, $col, $doc ) = @_;

    my $key = "lock__" . $db . "__" . $col;
    $key .=  "__" . $doc->{'identifier'};
    $key .=  "__" . $doc->{'start'};
    $key .=  "__" . $doc->{'end'};

    return $key;
}

sub _release_locks {
    my ( $self ) = @_;

    log_debug("Releasing " . scalar(@{$self->locks}) . " locks");

    foreach my $lock (@{$self->locks}){
	$self->locker->release($lock);
    }

    $self->_set_locks([]);

    return 1;
}

1;

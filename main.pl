#!/usr/bin/env perl
use v5.014;
use warnings;

# Perl WebSocket test client
#  Greg Kennedy 2019

use FindBin;
use lib "$FindBin::Bin";

use Net::Discord;

use Data::Dumper;

#####################

# Client config goes here
my $token = 'YOUR_TOKEN_HERE';

# Create bot client object
my $client = Net::Discord->new(token => $token);

# Provide callbacks for different events
#  Callbacks receive the client as their first parameter, and
#  the raw object as their second.
$client->register('READY', sub { print "Ready: " . Dumper(@_) } );
$client->register('MESSAGE_CREATE', sub { print "Message received: " . Dumper(@_) } );

# Run client in background
$client->run();

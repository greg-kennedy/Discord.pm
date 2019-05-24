#!/usr/bin/env perl
use v5.014;
use warnings;

# Perl WebSocket test client
#  Greg Kennedy 2019

use FindBin;
use lib "$FindBin::Bin";

use Net::Discord;

#####################

# Client config goes here
my $token = 'YOUR_TOKEN_HERE';

# Create bot client object
my $client = Net::Discord->new(token => $token);

# Run client
$client->run();

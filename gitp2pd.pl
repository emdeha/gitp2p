#!/usr/bin/env perl

use strict;
use warnings;
use v5.020;


use FindBin;
use lib "$FindBin::Bin/lib";

use Path::Tiny;
use Method::Signatures;
use IO::Async::Stream;
use IO::Async::Loop;
use List::MoreUtils qw/indexes firstidx/;
use JSON::XS;
use Log::Log4perl;
use File::pushd;

use GitP2P::Proto::Daemon;
use GitP2P::Proto::Relay;
use GitP2P::Core::Common;
use GitP2P::Core::Finder;

use App::Daemon qw/daemonize/;
daemonize();


if (! -e "$FindBin::Bin/etc/gitp2p-log.conf") {
    die "Log config file not found";
}


Log::Log4perl::init_and_watch("$FindBin::Bin/etc/gitp2p-log.conf", 'HUP');
my $log = Log::Log4perl->get_logger("gitp2pd");  


my %operations = ( "list"           => \&on_list,
                 , "fetch-pkt-line" => \&on_fetch,
                 , "hugz"           => \&on_hugz,
                 );

# TODO: Passing configs around ain't clever
die "Usage: ./gitp2pd <cfg_path> [--add]"
    if scalar @ARGV == 0;
my $cfg_path = $ARGV[0];
my $cfg_file = "$cfg_path/daemon-cfg";
my $is_add = 1 if defined $ARGV[1]; # Should we announce ourselves to the relay on startup

$log->logdie("Config doesn't exist") unless path($cfg_file)->exists;

my $cfg = JSON::XS->new->ascii->decode(path($cfg_file)->slurp);


if ($is_add) {
    # Hickaty hack
    # TODO: BAD BAD BAD!
    my $dir = pushd $cfg->{repos}->{"clone-simple"} . "../";

    # Add daemon to relay
    my $user_id = qx(git config --local --get user.email);
    chomp $user_id;
    # We use only the ref to which our HEAD points for testing purposes.
    # A proper implementation should query all available refs and send them to
    # the relay.
    my $last_ref_sha = qx(git rev-list HEAD --max-count=1);
    chomp $last_ref_sha;
    my $last_ref_name = qx(git symbolic-ref HEAD);
    chomp $last_ref_name;
    my $last_ref = $last_ref_sha . "?" . $last_ref_name;
    $log->info("Dir: '$dir'");
    $log->info("Last ref: '$last_ref'");

    my $cfg = JSON::XS->new->ascii->decode(path("$cfg_path/gitp2p-config")->slurp);
    my $s = GitP2P::Core::Finder::connect_to_relay(\$cfg, $cfg->{port_daemon});
    my $relay_add_msg = GitP2P::Proto::Relay::build("add-peer",
        ["clone-simple", $user_id, $last_ref]);
    $s->send($relay_add_msg);

    my $resp = <$s>;
    chomp $resp;

    close $s;
}


# WARN: pushd to the correct repo before calling this function!
func i_determine_newest_refs(ArrayRef[Str] $ref_lines) {
    my %newest_refs;

    for my $ref_line (@{$ref_lines}) {
        my ($ref_name, $ref_shas) = split / /, $ref_line;

        $ref_shas =~ s/,/\\|/g;
        my @have_refs = split /\n/, qx(git rev-list $ref_name | grep "$ref_shas");
        
        if (@have_refs) {
            $newest_refs{$ref_name} = $have_refs[0];
        }
    }

    return %newest_refs;
}

# Lists refs for a given repo
func on_list(Object $sender, GitP2P::Proto::Daemon $msg) {
    my ($repo, @refs) = split /\n/, $msg->op_data;

    if ($repo !~ /^repo \S+$/) {
        $log->logdie("Invalid repo line format: '$repo'")
    }

    my (undef, $repo_name) = split / /, $repo;

    $log->info("Processing refs: [@refs]");
    my $dir = pushd $cfg->{repos}->{$repo_name} . "../";

    my %newest_refs = i_determine_newest_refs(\@refs);

    for my $ref_name (keys %newest_refs) {
        my $list_ack_msg = GitP2P::Proto::Daemon::build_comm(
            "list_ack", [$ref_name, $newest_refs{$ref_name}, "\n"]);
        $log->info("list_ack: $list_ack_msg");
        $sender->write($list_ack_msg);
    }

    $sender->write("end\n");
}

# Returns wanted object by client
func on_fetch(Object $sender, GitP2P::Proto::Daemon $msg) { 
    my $objects = $msg->op_data;

    my ($repo, $id, @rest) = split /\n/, $objects;

    die "Invalid repo line format: '$repo'"
        if $repo !~ /^repo \S+ \S+$/;
    my (undef, $repo_name, $repo_owner) = split / /, $repo;

    die "Invalid id line format: '$id'"
        if $id !~ /^id \d+ \d+$/;
    my (undef, $beg, $step) = split / /, $id;

    my @wants;
    my @haves;
    for my $pkt_line (@rest) {
        if ($pkt_line =~ /^(\w+)\s([a-f0-9]{40})\n?$/) {
            $1 eq "want"
                and push @wants, $2;
            $1 eq "have"
                and push @haves, $2;
        }
    }

    my $repo_path = $cfg->{repos}->{$repo_name} . "/../";
    # TODO: List objects based on the refs that `wants' contains
    my @objects = GitP2P::Core::Common::list_objects($repo_path);
    for my $have (@haves) { # Hacking my way through life
        @objects = grep { $_ !~ /^$have/ } @objects;
    }

    # Get every $step-th object beggining from $beg
    @objects = @objects[map { $_ += $beg } indexes { $_ % $step == 0 } (0..$#objects)];
    @objects = grep { defined $_ } @objects;
    $log->info("objects \n" . join "", @objects);

    my $config_file = $cfg->{repos}->{$repo_name} . "/config";
    my $user_id = qx(git config --file $config_file --get user.email);

    my $pack_data = GitP2P::Core::Common::create_pack_from_list(\@objects, $repo_path);
    $log->info("pack_data: '$pack_data'");

    my $pack_msg = GitP2P::Proto::Daemon::build_data(
        "recv_pack", \$pack_data);
    $log->info("pack_msg: '$pack_msg'");
    sleep $cfg->{debug_sleep} if exists $cfg->{debug_sleep};
    $sender->write($pack_msg . "\n");
    $sender->write("end\n");
}

# Answers to a heartbeat
func on_hugz(Object $sender, GitP2P::Proto::Daemon $msg) {
    my $hugz_back = GitP2P::Proto::Daemon::build_comm("hugz-back", [""]);
    # sleep $cfg->{debug_sleep} if exists $cfg->{debug_sleep};
    $sender->write($hugz_back . "\n"); # I don't know who's gonna hug the pieces that die
}


my $loop = IO::Async::Loop->new;

$loop->listen(
    service => $cfg->{port},
    socktype => 'stream',

    on_stream => sub {
        my ($stream) = @_;
        $log->info("HAS STREAM $stream");

        $stream->configure(
            on_read => sub {
                my ($sender, $buffref, $eof) = @_;
                return 0 if $eof;

                my $msg = GitP2P::Proto::Daemon->new;
                $log->info("Message: $$buffref");
                $msg->parse(\$$buffref);

                if (not exists $operations{$msg->op_name}) {
                    my $cmd = $msg->op_name;
                    $log->info("Invalid command: " . $msg->op_name . "\n");
                    $sender->write("NACK: Invalid command - '$cmd'\n");
                } else {
                    $log->info("Exec command: " . $msg->op_name . "\n");
                    $operations{$msg->op_name}->($sender, $msg);
                }

                $$buffref = "";

                return 0;
            }
        );

        $loop->add($stream);
    },

    on_resolve_error => sub { $log->info("Cannot resolve - $_[0]\n"); },
    on_listen_error => sub { $log->info("Cannot listen\n"); },
);

$log->info("Starting loop");
$loop->run;

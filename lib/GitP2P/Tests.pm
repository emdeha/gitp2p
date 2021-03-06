package GitP2P::Tests;

use strict;
use warnings;
use v5.020;


BEGIN {
    require Exporter;
    our @ISA = qw/Exporter/;
    our @EXPORT = qw/&create_simple_dir_layout &create_simple_config_layout &init_cloned_repo/;
}


use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use Path::Tiny;
use File::pushd;
use JSON::XS;


sub create_simple_dir_layout {
    my $test_dir = shift;
    my $user_dir = shift;
    my $repo_name = shift;

    my $repo_dir = "$Bin/$test_dir/$user_dir/$repo_name/";
    path($repo_dir)->mkpath;
    path("$test_dir/$user_dir/log")->mkpath;
    path("$test_dir/$user_dir/etc")->mkpath;

    return $repo_dir;
}

sub create_simple_config_layout {
    my $repo_dir = shift;
    my $daemon_port = shift;
    my $debug_sleep = shift;


    # Create gitp2p-config
    my $gitp2p_cfg_cnts = JSON::XS->new->pretty(1)->encode({
            relays => { localhost => "localhost:12500" },
            preferred_relay => "localhost",
            port_daemon => $daemon_port,
            port_relay => 12500,
            port_hugz => 12501,
            peers_file => "/media/files/PROJECTS/gitp2p/peers"
        });
    path("$repo_dir/../etc/gitp2p-config")->touch->spew($gitp2p_cfg_cnts);


    # Create daemon cfg
    my $daemon_cfg_cnts = JSON::XS->new->pretty(1)->encode({
            repos => { "clone-simple" => "$repo_dir/.git/" },
            port => $daemon_port,
            debug_sleep => $debug_sleep
        });
    my $daemon_cfg = path("$repo_dir/../etc/daemon-cfg")->touch;
    $daemon_cfg->spew($daemon_cfg_cnts);
}

sub init_cloned_repo {
    my %params = @_;

    my $repo_dir = create_simple_dir_layout($params{test_dir},
                                            $params{user_dir}, 
                                            $params{repo_name});
    create_simple_config_layout($repo_dir, $params{daemon_port}, $params{debug_sleep});

    my $dir = pushd "$repo_dir/../";
    my $clone_cmd = Git::Repository->command("clone", $params{clone_from});

    my $stderr = $clone_cmd->stderr();
    while (<$stderr>) {
        print;
    }
    $clone_cmd->close;

    return $repo_dir;
}


1;

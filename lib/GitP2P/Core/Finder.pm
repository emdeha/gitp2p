package GitP2P::Core::Finder;

use v5.20;

use Moose;
use Method::Signatures;
use Path::Tiny;
use IO::Socket::INET;


func get_relay(Str $config_file_name is ro) {
    my @config = path($config_file_name)->lines;
    my ($relay_list) = grep { /relays=/ } @config;
    my @relays = split /,/, (split /=/, $relay_list)[1];

    return $relays[0];
}

func establish_connection(Str $address, Int $cfg) {
    my $local_port = 47778;
    $local_port = int ((path($cfg)->lines({chomp=>1}))[0]) if defined $cfg;
    my $s = IO::Socket::INET->new(PeerAddr => $address,
                                  LocalPort => $local_port,
                                  ReuseAddr => SO_REUSEADDR,
                                  ReusePort => SO_REUSEPORT,
                                  Proto => 'tcp')
                             or die "Cannot create connection";
    return $s;
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;

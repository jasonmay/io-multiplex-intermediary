#!perl
package IO::Multiplex::Intermediary::Client;
use Moose;
use namespace::autoclean;

use IO::Socket;
use JSON;

local $| = 1;

has socket => (
    is         => 'rw',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
    clearer    => 'clear_socket',
);

sub _build_socket {
    my $self = shift;
    my $socket = IO::Socket::INET->new(
        PeerAddr => $self->host,
        PeerPort => $self->port,
        Proto    => 'tcp',
    ) or die $!;

    return $socket;
}

has host => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => 'localhost',
);

has port => (
    is      => 'ro',
    isa     => 'Int',
    lazy    => 1,
    default => 9000
);

sub parse_input {
    my $self  = shift;
    my $input = shift;

    $input =~ s/[\r\n]*$//;
    $self->socket->send( $self->parse_json($input) . "\n");
};

sub build_response {
    my $self     = shift;
    my $wheel_id = shift;
    my $input    = shift;

    return $input;
}

sub connect_hook {
    my $self   = shift;
    my $data   = shift;

    return to_json({param => 'null'});
}

sub input_hook {
    my $self   = shift;
    my $data   = shift;

    return to_json(
        {
            param => 'output',
            data => {
                value => $self->build_response(
                    $data->{data}->{id},
                    $data->{data}->{value}
                ),
                id => $data->{data}->{id},
            }
        }
    );
}

sub disconnect_hook {
    my $self   = shift;
    my $data   = shift;

    my $id = $data->{data}->{id};

    return to_json(
        {
            param => 'disconnect',
            data  => {
                success => 1,
            },
        }
    );
}

sub parse_json {
    my $self = shift;
    my $json = shift;
    my $data = eval { from_json($json) };

    if ($@) { warn $@; return }

    my %actions = (
        'connect'    => sub { $self->connect_hook($data)    },
        'input'      => sub { $self->input_hook($data)      },
        'disconnect' => sub { $self->disconnect_hook($data) },
    );

    return $actions{ $data->{param} }->()
        if exists $actions{ $data->{param} };


    return to_json({param => 'null'});
}

sub force_disconnect {
    my $self = shift;
    my $id = shift;
    my %args = @_;

    $self->socket->send(to_json +{
            param => 'disconnect',
            data => {
                id => $id,
                %args,
            }
        }
    );
}

sub send {
    my $self = shift;
    my ($id, $message) = @_;

    $self->socket->send(to_json +{
            param => 'output',
            data => {
                value => $message,
                id => $id,
            }
        }
    );
}

sub cycle {
    my $self = shift;

    my $buf;
    $self->socket->recv($buf, 1024);
    return 0 unless $buf;

    $self->parse_input($buf);
    return 1;
}

sub run {
    my $self = shift;
    1 while $self->cycle;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

IO::MUlltiplex::Intermediary::Client - base controller for the server

=head1 SYNOPSIS

    package Controller;
    use Moose;
    extends 'IO::Multiplex::Intermediary';

    around build_response => sub {
        my $orig = shift;
        my $self = shift;

        my $response = $self->$orig(@_);

        return rot13($response);
    };

    around connect_hook => sub {
        my $orig = shift;
        my $self = shift;
        my $data = shift;

        $players{ $data->{data}{id} } = new_player;

        return $self->$orig(@_);
    };

    around input_hook => sub {
        my $orig = shift;
        my $self = shift;

        return $self->$orig(@_);
    };

    around disconnect_hook => sub {
        my $orig   = shift;
        my $self   = shift;
        my $data   = shift;

        my $id = $data->{data}->{id};
        my $player = delete $self->universe->players->{$id};

        return $self->$orig($data, @_);
    };

=head1 DESCRIPTION

B<WARNING! THIS MODULE HAS BEEN DEEMED ALPHA BY THE AUTHOR. THE API
MAY CHANGE IN SUBSEQUENT VERSIONS.>

The flow of the controller starts when a end connection sends a
command.  The controller figures out who sent the command and relays
it to the logic that reads the command and comes up with a response
(Application).

   Connections
       |
       v
     Server
       ^
       |
       V
     Client
       ^
       |
       v
  Application

=head1 ATTRIBUTES

=over

=item host

This attribute is for the host on which the server runs.

=item port

This attribute is for the host on which the server runs on.

=back

=head1 METHODS

=over

=item run

=item send

=back

=head1 AUTHOR

Jason May <jason.a.may@gmail.com>

=head1 LICENSE

This library is free software and may be distributed under the same
terms as perl itself.

=cut

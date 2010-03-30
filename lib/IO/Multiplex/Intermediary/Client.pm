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
    warn "get ready to RECV";
    $self->socket->recv($buf, 1024);
    warn "here: $buf!!";
    return 0 unless $buf;

    $self->parse_input($buf);
    return 1;
}

sub run {
    my $self = shift;
    1 while $self->cycle;
}

=head1 NAME

IO::Multiplex::Intermediary::Client - client logic

=head1 SYNOPSIS

  my $client = IO::Multiplex::Intermediary::Client->new;

=head1 DESCRIPTION

The flow of the controller starts when a player sends a command.
The controller figures out who sent the command and relays it to
the logic that reads the command and comes up with a response (Game).

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

This attribute is for the host the server runs on.

=item port

This attribute is for the host the server runs on.

=back

=head1 METHODS

=over

=item run

=item send

=back

=cut

__PACKAGE__->meta->make_immutable;

1;

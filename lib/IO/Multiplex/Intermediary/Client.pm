#!perl
package IO::Multiplex::Intermediary::Client;
use IO::Socket;
use POE qw(Component::Client::TCP Wheel::ReadWrite);
use Moose;
use namespace::autoclean;
use JSON;
use Carp;
use DDS;

local $| = 1;

has socket => (
    is       => 'rw',
    isa      => 'POE::Wheel::ReadWrite',
    clearer  => 'clear_socket',
);

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

sub BUILD {
    my $self = shift;
    $self->_client_start;
}

sub custom_startup { }

# start the server
sub _client_start {
   my ($self) = @_;
    POE::Component::Client::TCP->new(
        RemoteAddress   => $self->host,
        RemotePort      => $self->port,
        Connected       => sub { _server_connect($self,    @_) },
        Disconnected    => sub { _server_disconnect($self, @_) },
        ServerInput     => sub { _server_input($self,      @_) },
    );

    $self->custom_startup(@_);
}

# handle client input
sub _server_connect {
    my $self = shift;
    $self->socket($_[HEAP]{server});
};

# handle client input
sub _server_disconnect {
    my $self = shift;
    $self->clear_socket;
    delete $_[HEAP]{server};
};

# handle client input
sub _server_input {
    my $self = shift;
    my ($input) = $_[ARG0];
    $input =~ s/[\r\n]*$//;
    $_[HEAP]{server}->put($self->parse_json($input));
};

sub response_hook {
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
                value => $self->_response(
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

    $self->socket->put(to_json(
        {
            param => 'disconnect',
            data => {
                id => $id,
                %args,
            }
        }
    ));
}

sub send {
    my $self = shift;
    my ($id, $message) = @_;

    $self->socket->put(to_json(
        {
            param => 'output',
            data => {
                value => $message,
                id => $id,
            }
        }
    ));
}


sub run {
    my $self = shift;
    POE::Kernel->run();
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

=item custom_startup

=item send

=back

=cut

__PACKAGE__->meta->make_immutable;

1;

#!perl
package IO::Multiplex::Intermediary::Client;
use Moose;
use namespace::autoclean;

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use JSON;
use Data::UUID::LibUUID;

use Scalar::Util qw(weaken reftype);

local $| = 1;

has handle => (
    is         => 'rw',
    isa        => 'AnyEvent::Handle',
    lazy_build => 1,
    clearer    => 'clear_socket',
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

has _handle_guard => (
    is => 'rw',
    isa => 'AnyEvent::Util::guard',
);

has _timer_guard => (
    is => 'rw',
    isa => 'Any',
);

has _condvar => (
    is => 'ro',
    isa => 'AnyEvent::CondVar',
    default => sub { AnyEvent->condvar },
);

sub build_response {
    my $self     = shift;
    my $wheel_id = shift;
    my $input    = shift;

    return $input;
}

sub connect_hook {
    my $self   = shift;
    my $data   = shift;

    return +{param => 'null'};
}

sub input_hook {
    my $self   = shift;
    my $data   = shift;
    my $txn_id = shift;

    my $response = +{
        param => 'output',
        data => {
            value => $self->build_response(
                $data->{data}{id},
                $data->{data}{value},
                $txn_id,
            ),
            id => $data->{data}{id},
        },
        txn_id => $txn_id,
    };

    return $response;
}

sub disconnect_hook {
    my $self   = shift;
    my $data   = shift;

    my $id = $data->{data}->{id};

    return + {
        param => 'disconnect',
        data  => {
            success => 1,
        },
        txn_id => new_uuid_string(),
    }
}

sub _dispatch_data {
    my $self = shift;
    my $data = shift;
    my $txn_id = shift;

    my %actions = (
        'connect'    => sub { $self->connect_hook(@_)    },
        'input'      => sub { $self->input_hook(@_)      },
        'disconnect' => sub { $self->disconnect_hook(@_) },
    );

    return $actions{ $data->{param} }->($data, $txn_id)
        if exists $actions{ $data->{param} };


    return +{param => 'null'};
}

sub force_disconnect {
    my $self     = shift;
    my $id       = shift;
    my $txn_id   = shift;
    my @dep_txns = @_;

    my $data = +{
        param => 'disconnect',
        data => {
            id => $id,
        },
        txn_id   => $txn_id || new_uuid_string(),
        dep_txns => [@dep_txns],
    };

    $self->handle->push_write(json => $data);
}

sub send {
    my $self = shift;
    my ($id, $message, $txn_id, @dep_txns) = @_;

    $txn_id ||= new_uuid_string();
    my $data = +{
        param => 'output',
        data => {
            value => $message,
            id    => $id,
        },
        txn_id => $txn_id,
        dep_txns => [@dep_txns],
    };

    #use DDS;
    #warn Dump($data)->Out . ' result' if @dep_txns;
    $self->handle->push_write(json => $data);
}

sub multisend {
    my $self = shift;
    my %ids  = @_;

    my @refs;
    while (my ($id, $message) = each %ids) {
        push @refs, +{
            param => 'output',
            data => {
                value => $message,
                id    => $id,
            },
            txn_id => new_uuid_string(),
        };

    }

    $self->handle->push_write(json => \@refs);
}

sub tick {
    # stub
}

sub BUILD {
    my $self = shift;
    weaken( my $weakself = $self );
    my $guard = tcp_connect $self->host, $self->port, sub {
        print "Connected!\n";
        my ($fh, $host, $port) = @_ or do {
            # friggin tcp_connect catches dies
            warn sprintf(
                "unable to connect to %s on %s",
                $self->host,
                $self->port
            );

            exit(1);
        };

        my $handle = AnyEvent::Handle->new(
            fh => $fh,
            on_read => sub {
                my $h = shift;
                $h->push_read(
                    json => sub {
                        my $handle = shift;
                        my $data = shift;
                        my @elements = reftype $data eq 'ARRAY'
                                     ? @$data
                                     : ($data);

                                     #use DDS;
                        foreach my $element (@elements) {
                            my $txn_id = new_uuid_string();
                            my $result = $weakself->_dispatch_data($element, $txn_id);
                            $handle->push_write(json => $result);
                            #warn Dump($result)->Out . " result";
                        }
                    }
                );
            },
            on_error => sub {
                my ($fh, $fatal, $error) = @_;

                warn $error;
                $fh->destroy if $fatal;
                $weakself->_condvar->send;
            },
        );

        $self->handle($handle);
    };
    $self->_handle_guard($guard);
}

sub run {
    my $self = shift;
    $self->_condvar->wait;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

IO::Multiplex::Intermediary::Client - base controller for the server

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

        delete $player{ $data->{data}{id} };
        return $self->$orig($data, @_);
    };

=head1 DESCRIPTION

B<WARNING! THIS MODULE HAS BEEN DEEMED ALPHA BY THE AUTHOR. THE API
MAY CHANGE IN SUBSEQUENT VERSIONS.>

The flow of the controller starts when an end connection sends a
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

This module supplies you with these attributes which you can pass to
the constructor as named arguments:

=over

=item C<host>

This attribute is for the host on which the server runs.

=item C<port>

This attribute is for the host on which the server runs on.

=back

=head1 METHODS

=over

=item C<run>

Starts the client, which connects to the intermediary and waits for
input to respond to.

=item C<send($id, $message)>

Tells the intermediary to output C<$message> to the user with the ID
C<$id>.

=item C<multisend($id =E<gt> $message, $id =E<gt> $message, ...)>

Tells the intermediary to output various messages to its corresponding
IDs.

=back

=head1 HOOKS

These are internal methods with the primary purposes of hooking from
the outside for a more flexible and extensive use.

=over

=item C<build_response>

This hook is a method that you want to hook for doing your response
handling and output manipulateion (see the L</SYNOPSIS> section).  As the
method stands, C<build_response> returns exactly what was input to
the method, making the application a simple echo server.

=item C<connect_hook>

This hook runs after a user connects. It returns JSON data that
tells the intermediary that it has acknowledge the user has
connected.

=item C<input_hook>

This hook runs after the intermediary sends an input request. It
returns a JSON output request which contains the response build by
C<build_response>.

=item C<disconnect_hook>

This hook runs after a user disconnects. It has the same behavior
as the C<connect_hook> method, just with disconnect information.

=item C<tick>

This hook runs on the second every second. By itself, it is does
not do anything. Hooking from other applications is its only purpose.

=back

=head1 AUTHOR

Jason May <jason.a.may@gmail.com>

=head1 LICENSE

This library is free software and may be distributed under the same
terms as perl itself.

=cut

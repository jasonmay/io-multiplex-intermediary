#!/usr/bin/env perl
package IO::Multiplex::Intermediary;
use MooseX::POE;
use namespace::autoclean;

use JSON;
use List::MoreUtils qw(any);
use Scalar::Util qw(reftype);

use POE qw(
    Wheel::SocketFactory
    Component::Server::TCP
    Wheel::ReadWrite
    Filter::Stream
);

has external_sockets => (
    is  => 'rw',
    isa => 'POE::Wheel::SocketFactory',
);

has rw_set => (
    is => 'rw',
    isa => 'HashRef[Int]',
    default => sub { +{} },
);

has external_port => (
    is  => 'ro',
    isa => 'Int',
    default => 6715
);

has controller_socket => (
    is      => 'rw',
    isa     => 'POE::Wheel::ReadWrite',
);

has controller_port => (
    is  => 'ro',
    isa => 'Int',
    default => 9000
);

has controller_connected => (
    is  => 'rw',
    isa => 'Bool',
    default => 0
);

has socket_info => (
    is  => 'rw',
    isa => 'HashRef[Int]',
    default => sub { +{} },
);

sub _start {
    my ($self) = @_;
    $self->external_sockets(
        POE::Wheel::SocketFactory->new(
            BindPort     => $self->external_port,
            SuccessEvent => 'client_accept',
            FailureEvent => 'server_error',
            Reuse        => 'yes',
        )
    );

    POE::Component::Server::TCP->new(
        Port               => $self->controller_port,
        ClientConnected    => sub { $self->_controller_client_accept(@_) },
        ClientDisconnected => sub { $self->_controller_server_error(@_)  },
        ClientInput        => sub { $self->_controller_client_input(@_)  },
    );
}

#TODO send backup info
sub _controller_client_accept {
    my $self = shift;

    $self->controller_socket($_[HEAP]->{client});

    if ( scalar(%{$self->rw_set}) ) {
        foreach my $id (keys %{ $self->rw_set }) {
            $self->send_to_controller(
                {
                    param => 'connect',
                    data  => {
                        id    => $id,
                    }
                }
            );
        }
    }
}

sub _client_accept {
    my ($self) = @_;
    my $socket = $_[ARG0];
    my $rw = POE::Wheel::ReadWrite->new(
        Handle     => $socket,
        Driver     => POE::Driver::SysRW->new,
        Filter     => POE::Filter::Stream->new,
        InputEvent => 'client_input',
        ErrorEvent => 'client_error',
    );

    my $wheel_id = $rw->ID;
    $self->rw_set->{$wheel_id} = $rw;

    $self->send_to_controller(
        {
            param => 'connect',
            data  => {
                id    => $wheel_id,
            }
        }
    );
}

sub _client_input {
    my ($self)             = @_;
    my ($input, $wheel_id) = @_[ARG0, ARG1];
    $input =~ s/[\r\n]*$//;

    $self->send_to_controller(
        {
            param => 'input',
            data => {
                id    => $wheel_id,
                value => $input,
            }
        }
    );
}

sub _controller_client_input {
    my $self = shift;
    my $input = $_[ARG0];
    chomp($input);
    my $json = eval { from_json($input) };

    {
        if ($@ || !$json) {
            warn "JSON error: $@";
        }
        elsif (!exists $json->{param}) {
            warn "Invalid JSON structure!";
        }
        else {
            last unless $json->{data}->{id};
            last unless reftype($self->rw_set);
            last unless $self->rw_set->{ $json->{data}->{id} };

            if ($json->{param} eq 'output') {
                $self->rw_set->{ $json->{data}->{id} }->put( $json->{data}->{value} );
                if ($json->{updates}) {
                    foreach my $key  (%{ $json->{updates} }) {
                        my $value = $json->{updates}->{$key};
                        $self->socket_info->{ $json->{data}->{id} }->{ $key } = $value
                    }
                }
            }
            elsif ($json->{param} eq 'disconnect') {
                my $id = $json->{data}->{id};
                $self->rw_set->{$id}->shutdown_output;
            }
        }
    }

}

sub _client_error {
    my ($self)   = @_;
    my $wheel_id = $_[ARG3];
    delete $self->rw_set->{$wheel_id};
    $self->send_to_controller(
        {
            param => 'disconnect',
            data => {
                id => $wheel_id,
            }
        }
    );
}

#TODO clean shutdown etc
sub _server_error {
    #stub
}

sub _controller_server_error {
    #stub
}


sub send {
    my $self = shift;
    my $id = shift;
    my $data = shift;

    $self->rw_set->{$id}->put(to_json($data));
}

sub send_to_controller {
    my $self   = shift;
    my $data   = shift;

    return unless defined $self->controller_socket;
    $self->controller_socket->put(to_json($data));
}


sub run {
    my $self = shift;
    POE::Kernel->run();
}

event START                => \&_start;

event client_accept => \&_client_accept;
event server_error  => \&_server_error;
event client_input  => \&_client_input;
event client_error  => \&_client_error;

#event controller_client_input   => \&_controller_client_input;
##event controller_client_accept  => \&_controller_client_accept;
#event controller_client_error   => \&_controller_client_error;

__PACKAGE__->meta->make_immutable;

1;

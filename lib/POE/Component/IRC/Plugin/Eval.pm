package POE::Component::IRC::Plugin::Eval;

use strict;
use warnings;
use Carp 'croak';
use POE;
use POE::Component::IRC::Common qw(strip_color strip_formatting),
    qw(parse_user irc_to_utf8 NORMAL DARK_GREEN ORANGE TEAL BROWN);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);
use POE::Filter::JSON;
use POE::Wheel::ReadWrite;
use POE::Wheel::SocketFactory;

sub new {
    my ($package, %args) = @_; 
    my $self = bless \%args, $package;

    if (ref $self->{Channels} ne 'ARRAY' || !$self->{Channels}) {
        croak __PACKAGE__ . ': No channels defined';
    }

    $self->{Server_host} = 'localhost' if !defined $self->{Server_port};
    $self->{Server_port} = 14400       if !defined $self->{Server_port};
    $self->{Method}      = 'notice'    if !defined $self->{Method};
    $self->{Color}       = 1           if !defined $self->{Color};
    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    my $botcmd;
    if (!(($botcmd) = grep { $_->isa('POE::Component::IRC::Plugin::BotCommand') } values %{ $irc->plugin_list() })) {
        die __PACKAGE__ . " requires an active BotCommand plugin\n";
    }
    $botcmd->add(eval => 'Usage: eval <lang> <code>');
    $irc->plugin_register($self, 'SERVER', qw(botcmd_eval));
    $self->{irc} = $irc;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                connect_failed
                connected
                new_eval
                eval_read
                eval_error
            )],
        ],
    );

    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    delete $self->{evals};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];
    $self->{session_id} = $session->ID;
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub S_botcmd_eval {
    my ($self, $irc)  = splice @_, 0, 2;
    my $nick          = parse_user( ${ $_[0] } );
    my $chan          = ${ $_[1] };
    my ($lang, $code) = ${ $_[2] } =~ /^(\S+) (.*)/;

    $poe_kernel->post($self->{session_id}, 'new_eval', $nick, $chan, $lang, $code);
    return PCI_EAT_NONE;
}

sub new_eval {
    my ($self, $nick, $chan, $lang, $code) = @_[OBJECT, ARG0..$#_];

    my $sock_wheel = POE::Wheel::SocketFactory->new(
        RemoteAddress => $self->{Server_host},
        RemotePort    => $self->{Server_port},
        FailureEvent  => 'connect_failed',
        SuccessEvent  => 'connected',
    );

    print STDERR "socket id ".$sock_wheel->ID."\n";
    $self->{evals}{$sock_wheel->ID} = {
        nick       => $nick,
        chan       => $chan,
        lang       => $lang,
        code       => $code,
        sock_wheel => $sock_wheel,
    };

    return PCI_EAT_NONE;
}

sub connect_failed {
    my ($self, $reason, $id) = @_[OBJECT, ARG2, ARG3];
    my $irc = $self->{irc};

    print STDERR "$reason\n";
    my $eval = delete $self->{evals}{$id};
    my $msg = "Error: Couldn't connect to eval server: $reason";
    my $color = 'Error: '.BROWN."Couldn't connect to eval server: $reason".NORMAL;
    $irc->yield($self->{Method}, $eval->{chan}, ($self->{Color} ? $color : $msg));
    return;
}

sub connected {
    my ($self, $socket, $id) = @_[OBJECT, ARG0, ARG3];

    my $eval = $self->{evals}{$id};

    $eval->{rw_wheel} = POE::Wheel::ReadWrite->new(
        Handle     => $socket,
        Filter     => POE::Filter::JSON->new(),
        InputEvent => 'eval_read',
        ErrorEvent => 'eval_error',
    );

    $eval->{rw_wheel}->put({
        lang => $eval->{lang},
        code => $eval->{code},
    });

    return;
}

sub eval_error {
    my ($self, $reason, $rw_id) = @_[OBJECT, ARG2, ARG3];
    my $irc = $self->{irc};

    print STDERR "$reason\n";
    my $eval;
    for my $eval_id (keys %{ $self->{evals} }) {
        if ($self->{evals}{$eval_id}{rw_wheel}->ID == $rw_id) {
            $eval = delete $self->{evals}{$eval_id};
            last;
        }
    }

    my $msg = "Failed to read from evalserver socket: $reason";
    my $color = 'Error: '.BROWN."Failed to read from evalserver socket: $reason".NORMAL;
    $irc->yield($self->{Method}, $eval->{chan}, ($self->{Color} ? $color : $msg));

    return;
}

sub eval_read {
    my ($self, $return, $rw_id) = @_[OBJECT, ARG0, ARG1];
    my $irc = $self->{irc};

    my $eval;
    for my $eval_id (keys %{ $self->{evals} }) {
        if ($self->{evals}{$eval_id}{rw_wheel}->ID == $rw_id) {
            $eval = delete $self->{evals}{$eval_id};
            last;
        }
    }

    if ($return->{error}) {
        my $msg = "Error: Failed to eval code: $return->{error}";
        my $color = 'Error: '.BROWN."Failed to eval code: $return->{error}".NORMAL;
        $irc->yield($self->{Method}, $eval->{chan}, ($self->{Color} ? $color : $msg));
    }
    else {
        $return->{result} = 'undef' if !defined $return->{result};
        $return->{result} = _clean($return->{result});
        $return->{output} = _clean($return->{output});

        my $msg = "Result: «$return->{result}» · Memory: $return->{memory}kB";
        $msg .= " · Output: «$return->{output}»" if length $return->{output};

        my $color = 'Result: '.DARK_GREEN.'«'.NORMAL.$return->{result}.DARK_GREEN.'»'.NORMAL
                    .' Memory: '.ORANGE.$return->{memory}.NORMAL.'kB';
        $color .= ' Output: '.TEAL.'«'.NORMAL.$return->{output}.TEAL.'»'.NORMAL if length $return->{output};

        $irc->yield($self->{Method}, $eval->{chan}, ($self->{Color} ? $color : $msg));
    }

    return;
}

sub _clean {
    my ($string) = @_;
    $string =~ s/\n/␤/gm;
    $string = strip_color($string);
    $string = strip_formatting($string);
    return $string;
}

1;

=encoding utf8

=head1 NAME

POE::Component::IRC::Plugin::Eval - Evaluate code with App::EvalServer

=head1 SYNOPSIS

 use POE::Component::IRC::Plugin::Eval;

 # evluate code in #foobar
 $irc->plugin_add(Eval => POE::Component::IRC::Plugin::Eval->new(
     Server_port => 14400,
     Channels    => ['#foobar'],
 ));

=head1 DESCRIPTION

POE::Component::IRC::Plugin::Eval is a
L<POE::Component::IRC|POE::Component::IRC> plugin. It reads 'eval' commands
from IRC users and evaluates code with L<App::EvalServer|App::EvalServer>.

You must add a
L<POE::Component::IRC::Plugin::BotCommand|POE::Component::IRC::Plugin::BotCommand>
plugin to the IRC component before adding this plugin.

=head1 METHODS

=head2 C<new>

Takes the following arguments:

B<'Server_host'>, the host where the L<App::EvalServer|App::EvalServer>
instance is running. Default is 'localhost'.

B<'Server_port'>, the host where the L<App::EvalServer|App::EvalServer>
instance is running. Default is 14400.

B<'Channels'>, an array reference of channels to post messages to. You must
specify at least one channel.

B<'Method'>, how you want messages to be delivered. Valid options are
'notice' (the default) and 'privmsg'.

Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s C<plugin_add> method.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

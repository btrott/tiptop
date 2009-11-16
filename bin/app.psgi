#!/usr/bin/perl -w
use strict;

use lib '/Users/btrott/Documents/devel/faved-tp';
use lib '/Users/btrott/Documents/devel/WWW-TypePad/lib';

use Faved::Util;
use List::Util qw( first );
use Plack::App::File;
use Plack::App::URLMap;
use Plack::Builder;
use Template;
use Template::Provider::Encoding;
use Template::Stash::ForceUTF8;
use WWW::TypePad;

my $tt = Template->new(
    LOAD_TEMPLATES  => [
        Template::Provider::Encoding->new( INCLUDE_PATH => 'templates' )
    ],
    STASH           => Template::Stash::ForceUTF8->new,
);
my $tp = WWW::TypePad->new;

my $error = sub {
    my( $code, $html ) = @_;
    return [
        $code,
        [ 'Content-Type', 'text/html' ],
        [ $html ],
    ];
};

sub is_verb {
    my( $event, $verb ) = @_;
    my $found = first { $_ eq $verb } @{ $event->{verbs} };
    return $found ? 1 : 0;
}

sub is_type {
    my( $asset, $type ) = @_;
    my $found = first { $_ eq $type } @{ $asset->{objectTypes} };
    return $found ? 1 : 0;
}

sub get_notifications {
    my( $limit ) = @_;
    my @events;
    my $total;
    do {
        my $res = $tp->users->notifications(
            '6p00d83455876069e2',
            { 'start-index' => @events + 1 }
        );
        $total = $res->{totalResults};
        push @events, @{ $res->{entries} };
    } while ( @events < $limit && $total > @events );
    return \@events;
}

my $dashboard = sub {
    my $env = shift;

    my $events = get_notifications( 150 );

    my @assets;
    my $dur = DateTime::Format::Human::Duration->new;
    my $now = DateTime->now( time_zone => 'America/Los_Angeles' );
    for my $event ( @$events ) {
        next unless is_verb( $event, 'tag:api.typepad.com,2009:NewAsset' );

        my $asset = $event->{object};

        # Skip comments.
        next if is_type( $asset, 'tag:api.typepad.com,2009:Comment' );

        # Skip non-Post assets unless they're in a Motion group.
        next unless
            is_type( $asset, 'tag:api.typepad.com,2009:Post' ) ||
            $asset->{groups} && @{ $asset->{groups} };

        next if $asset->{source} && $asset->{source}{provider};

        $asset->{author}{avatar_uri} =
            Faved::Util->get_best_avatar_uri( $asset->{author}{links} );

        my $dt = DateTime::Format::ISO8601->parse_datetime( $asset->{published} );

        my( $type ) = $asset->{objectTypes}[0] =~ /(\w+)$/;
        my $permalink_rel_type = $type eq 'Link' ? 'target' : 'alternate';
        my $link = first { $_->{rel} eq $permalink_rel_type } @{ $asset->{links} };

        my $data = Faved::Util->get_content_data( $type, $asset->{content}, $asset->{links} );

        push @assets, {
            id          => $asset->{urlId},
            type        => $type,
            title       => $asset->{title},
            author      => $asset->{author},
            content     => $data,
            permalink   => $link->{href},
            published   => $dur->format_duration_between( $now, $dt ),
        };
    }

    my $param = $env->{QUERY_STRING} ?
        CGI::Deurl::XS::parse_query_string( $env->{QUERY_STRING} ) :
        {};
    $tt->process( 'assets.tt', { param => $param, assets => \@assets }, \my( $out ) )
        or return $error->( 500, $tt->error );
    Encode::_utf8_off( $out );

    return [
        200,
        [ 'Content-Type', 'text/html' ],
        [ $out ],
    ];
};

builder {
    mount '/css' => builder {
        Plack::App::File->new( { root => './css' } );
    };
    
    mount '/img' => builder {
        Plack::App::File->new( { root => './img' } );
    };
    
    mount '/js' => builder {
        Plack::App::File->new( { root => './js' } );
    };
    
    mount '/facebox' => builder {
        Plack::App::File->new( { root => './facebox' } );
    };

    mount '/' => $dashboard;
    mount '/favicon.ico' => sub { return $error->( 404, "not found" ) };
};
#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use Tiptop::Util;
use CGI::Cookie ();
use DateTime;
use DateTime::Format::Mail;
use Digest::HMAC_SHA1 ();
use JSON;
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

sub load_assets_by {
    my( $sql, @bind ) = @_;

    my $dbh = Tiptop::Util->get_dbh;
    my $sth = $dbh->prepare( <<SQL );
SELECT a.asset_id,
       a.api_id,
       a.title,
       a.content,
       a.permalink,
       a.favorite_count,
       UNIX_TIMESTAMP(CONVERT_TZ(a.created, '+00:00', 'SYSTEM')) AS published,
       a.links_json,
       a.object_type AS type,
       p.api_id AS person_api_id,
       p.display_name,
       p.avatar_uri
FROM asset a
JOIN person p ON p.person_id = a.person_id
$sql
SQL
    $sth->execute( @bind );

    my( @assets, %id2idx );
    while ( my $row = $sth->fetchrow_hashref ) {
        $row->{author} = {
            api_id          => delete $row->{person_api_id},
            display_name    => delete $row->{display_name},
            avatar_uri      => delete $row->{avatar_uri},
        };

        $row->{favorited_by} = [];

        my $dt = DateTime->from_epoch( epoch => $row->{published} );
        $row->{published} = {
            iso8601 => $dt->iso8601,
            web     => DateTime::Format::Mail->format_datetime( $dt ),
        };

        # Calculate an excerpt, extract media, etc, and stuff it all
        # into the "content" key.
        $row->{content} = Tiptop::Util->get_content_data(
            $row->{type},
            $row->{content},
            decode_json( $row->{links_json} ),
        );

        push @assets, $row;
        $id2idx{ $row->{asset_id} } = $#assets;
    }
    $sth->finish;

    # For each asset that we found, we want a list of the users who've
    # added the asset as a favorite. Construct a complex IN clause to
    # load the user records for display, and add them to the "favorited_by"
    # key in each asset row.
    my @ids = keys %id2idx;
    if ( @ids ) {
        my $in_sql = join ', ', ( '?' ) x @ids;
        my $sth = $dbh->prepare( <<SQL );
SELECT f.asset_id, p.api_id, p.display_name, p.avatar_uri
FROM favorited_by f
JOIN person p ON p.person_id = f.person_id
WHERE f.asset_id IN ($in_sql)
SQL
        $sth->execute( @ids );
        while ( my $row = $sth->fetchrow_hashref ) {
            my $asset_id = delete $row->{asset_id};
            my $idx = $id2idx{ $asset_id };
            push @{ $assets[ $idx ]{favorited_by} }, $row;
        }
        $sth->finish;
    }

    return \@assets;
}

sub process_tt {
    my( $env, $stash ) = @_;
    
    my %cookies = CGI::Cookie->parse( $env->{HTTP_COOKIE} );
    if ( my $cookie = $cookies{session_person_id} ) {
        my $person_id = session_cookie_to_person( $cookie->value );
        if ( $person_id ) {
            my $dbh = Tiptop::Util->get_dbh;
            $stash->{remote_user} = $dbh->selectrow_hashref( <<SQL, undef, $person_id );
SELECT api_id, display_name, avatar_uri
FROM person
WHERE person_id = ?
SQL
        }
    }

    my $tmpl = $stash->{param}{format} && $stash->{param}{format} eq 'partial' ?
        'assets_list.tt' : 'assets.tt';

    $tt->process( $tmpl, $stash, \my( $out ) )
        or return $error->( 500, $tt->error );
    Encode::_utf8_off( $out );

    return [
        200,
        [ 'Content-Type', 'text/html' ],
        [ $out ],
    ];
}

# Kind of lame. Should probably use Plack::Middleware::Session once the
# pure-cookie implementation is in a non-developer release.
sub person_to_session_cookie {
    my( $person_id ) = @_;
    my $secret = Tiptop::Util->config->{app}{session_secret};
    return join ':',
        $person_id,
        $secret ? Digest::HMAC_SHA1::hmac_sha1_hex( $person_id, $secret ) : '';
}

sub session_cookie_to_person {
    my( $value ) = @_;
    my( $person_id, $sig ) = split /:/, $value, 2;
    if ( my $secret = Tiptop::Util->config->{app}{session_secret} ) {
        return unless $sig eq Digest::HMAC_SHA1::hmac_sha1_hex(
            $person_id, $secret
        );
    }
    return $person_id;
}

sub uri_for {
    my( $env, $path ) = @_;
    $path = '/' . $path unless $path =~ m{^/};
    return 'http://' . $env->{HTTP_HOST} . $path;
}

my $leaders = sub {
    my $env = shift;

    my $param = $env->{QUERY_STRING} ?
        CGI::Deurl::XS::parse_query_string( $env->{QUERY_STRING} ) :
        {};
    my $offset = $param->{offset} || 0;

    # The client can ask for a specific day's worth of favorites by
    # specifying the /YYYY-MM-DD in the path; we default to the current day.
    my $start;
    if ( $env->{PATH_INFO} &&
         $env->{PATH_INFO} =~ /^\/(\d{4})\-(\d{2})\-(\d{2})$/ ) {
        $start = DateTime->new( year => $1, month => $2, day => $3 );
    } else {
        $start = DateTime->now->truncate( to => 'day' );
    }
    my $end = $start->clone->add( days => 1 );

    my $assets = load_assets_by( <<SQL, $start->ymd, $end->ymd );
WHERE a.favorite_count > 0 AND a.created BETWEEN ? AND ? ORDER BY a.favorite_count DESC LIMIT 20 OFFSET $offset
SQL

    return process_tt( $env, {
        uri         => $env->{REQUEST_URI},
        assets      => $assets,
        body_class  => 'leaders',
        param       => $param,
    } );
};

my $dashboard = sub {
    my $env = shift;

    my $param = $env->{QUERY_STRING} ?
        CGI::Deurl::XS::parse_query_string( $env->{QUERY_STRING} ) :
        {};
    my $offset = $param->{offset} || 0;

    # If we wanted to support a multi-user environment, we'd need a
    # "WHERE s.person_id = ?" clause.
    my $assets = load_assets_by( <<SQL );
JOIN stream s ON s.asset_id = a.asset_id
ORDER BY a.created DESC LIMIT 20 OFFSET $offset
SQL

    return process_tt( $env, {
        uri         => $env->{REQUEST_URI},
        assets      => $assets,
        body_class  => 'dashboard',
        param       => $param,
    } );
};

my $login = sub {
    my $env = shift;

    my $config = Tiptop::Util->config;
    my $tp = WWW::TypePad->new(
        consumer_key        => $config->{app}{consumer_key},
        consumer_secret     => $config->{app}{consumer_secret},
    );
    
    my $cb_uri = uri_for( $env, '/login-callback' );
    my $uri = $tp->oauth->get_authorization_url(
        callback => $cb_uri,
    );
    my $token_secret = $tp->oauth->request_token_secret;

    # Store the token secret in the browser cookies for when this user
    # returns from TypePad.
    my $cookie = CGI::Cookie->new(
        -name   => 'oauth_token_secret',
        -value  => $token_secret,
    );
    
    return [
        302,
        [
            Location        => $uri,
            'Set-Cookie'    => "$cookie",
        ],
    ];
};

my $login_cb = sub {
    my $env = shift;

    my $config = Tiptop::Util->config;
    my $tp = WWW::TypePad->new(
        consumer_key        => $config->{app}{consumer_key},
        consumer_secret     => $config->{app}{consumer_secret},
    );

    # request_token is passed back to us via the query string
    # as "oauth_token"...
    my $param = $env->{QUERY_STRING} ?
        CGI::Deurl::XS::parse_query_string( $env->{QUERY_STRING} ) :
        {};
    my $token = $param->{oauth_token}
        or return $error->( 400, 'No oauth_token' );

    # ... and the request_token_secret is stored in the browser cookie.
    my %cookies = CGI::Cookie->parse( $env->{HTTP_COOKIE} );
    my $token_secret = $cookies{oauth_token_secret} ?
        $cookies{oauth_token_secret}->value : undef;
    return $error->( 400, 'No oauth_token_secret cookie' )
        unless $token_secret;

    my $verifier = $param->{oauth_verifier}
        or return $error->( 400, 'No oauth_verifier' );

    $tp->oauth->request_token( $token );
    $tp->oauth->request_token_secret( $token_secret );

    my( $access_token, $access_token_secret ) =
        $tp->oauth->request_access_token( verifier => $verifier );
    $tp->access_token( $access_token );
    $tp->access_token_secret( $access_token_secret );

    # Now we've got an access token; make an authenticated request to figure
    # out who we are, so we can associate the OAuth tokens to a local user.
    my $obj = $tp->users->get( '@self' );
    return $error->( 500, 'Request for @self gave us empty result' )
        unless $obj;

    my $person = Tiptop::Util->find_or_create_person_from_api( $obj );
    Tiptop::Util->save_oauth_tokens(
        $person->{person_id},
        $access_token,
        $access_token_secret,
    );
    
    my $token_cookie = CGI::Cookie->new(
        -name       => 'oauth_token_secret',
        -value      => '',
        -expires    => '-1y',
    );
    
    my $session_cookie = CGI::Cookie->new(
        -name       => 'session_person_id',
        -value      => person_to_session_cookie( $person->{person_id} ),
        -expires    => '+30d',
    );

    return [
        302,
        [
            Location        => '/',
            'Set-Cookie'    => "$token_cookie",
            'Set-Cookie'    => "$session_cookie",
        ],
    ];
};

builder {
    mount '/static' => builder {
        Plack::App::File->new( { root => './static' } );
    };

    mount '/' => $dashboard;
    mount '/most' => $leaders;

    mount '/login' => $login;
    mount '/login-callback' => $login_cb;

    mount '/favicon.ico' => sub { return $error->( 404, "not found" ) };
};
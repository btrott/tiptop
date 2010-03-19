#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use DateTime;
use DateTime::Format::Mail;
use JSON;
use Plack::App::File;
use Plack::Builder;
use Plack::Request;
use Template;
use Template::Provider::Encoding;
use Template::Stash::ForceUTF8;
use Tiptop::Util;
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
       a.image_link,
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
            $row->{image_link} ? decode_json( $row->{image_link} ) : undef,
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
    my( $req, $stash ) = @_;

    if ( my $person_id = $req->session->{person_id} ) {
        my $dbh = Tiptop::Util->get_dbh;
        $stash->{remote_user} = $dbh->selectrow_hashref( <<SQL, undef, $person_id );
SELECT api_id, display_name, avatar_uri
FROM person
WHERE person_id = ?
SQL
    }

    my $tmpl = $req->query_parameters->{format} &&
               $req->query_parameters->{format} eq 'partial' ?
               'assets_list.tt' : 'assets.tt';

    $stash->{request} = $req;

    $tt->process( $tmpl, $stash, \my( $out ) )
        or return $error->( 500, $tt->error );
    Encode::_utf8_off( $out );

    my $res = Plack::Response->new( 200 );
    $res->content_type( 'text/html' );
    $res->body( $out );
    return $res->finalize;
}

sub Plack::Request::uri_for {
    my $req = shift;
    my( $path ) = @_;
    $path = '/' . $path unless $path =~ m{^/};
    return 'http://' . $req->env->{HTTP_HOST} . $path;
}

my $leaders = sub {
    my $req = Plack::Request->new( shift );

    my $offset = $req->query_parameters->{offset} || 0;

    # The client can ask for a specific day's worth of favorites by
    # specifying the /YYYY-MM-DD in the path; we default to the current day.
    my $start;
    if ( $req->path_info &&
         $req->path_info =~ /^\/(\d{4})\-(\d{2})\-(\d{2})$/ ) {
        $start = DateTime->new( year => $1, month => $2, day => $3 );
    } else {
        $start = DateTime->now->truncate( to => 'day' );
    }
    my $end = $start->clone->add( days => 1 );

    my $assets = load_assets_by( <<SQL, $start->ymd, $end->ymd );
WHERE a.favorite_count > 0 AND a.created BETWEEN ? AND ? ORDER BY a.favorite_count DESC LIMIT 20 OFFSET $offset
SQL

    return process_tt( $req, {
        assets      => $assets,
        body_class  => 'leaders',
    } );
};

my $dashboard = sub {
    my $req = Plack::Request->new( shift );

    my $offset = $req->query_parameters->{offset} || 0;

    # If we wanted to support a multi-user environment, we'd need a
    # "WHERE s.person_id = ?" clause.
    my $assets = load_assets_by( <<SQL );
JOIN stream s ON s.asset_id = a.asset_id
ORDER BY a.created DESC LIMIT 20 OFFSET $offset
SQL

    return process_tt( $req, {
        assets      => $assets,
        body_class  => 'dashboard',
    } );
};

my $login = sub {
    my $req = Plack::Request->new( shift );

    my $config = Tiptop::Util->config;
    my $tp = WWW::TypePad->new(
        consumer_key        => $config->{app}{consumer_key},
        consumer_secret     => $config->{app}{consumer_secret},
    );
    
    # After the user authorizes our application, he/she will be sent back
    # to the callback URI ($login_cb below).
    my $cb_uri = $req->uri_for( '/login-callback' );
    
    # Under the hood, get_authorization_url will request a request token,
    # then construct a URI to send the user to to authorize our app.
    my $uri = $tp->oauth->get_authorization_url(
        callback => $cb_uri,
    );
    
    my $res = Plack::Response->new;
    $res->redirect( $uri );

    # Store the token secret in the browser cookies for when this user
    # returns from TypePad.
    $res->cookies->{oauth_token_secret} = $tp->oauth->request_token_secret;

    return $res->finalize;
};

my $login_cb = sub {
    my $req = Plack::Request->new( shift );

    my $config = Tiptop::Util->config;
    my $tp = WWW::TypePad->new(
        consumer_key        => $config->{app}{consumer_key},
        consumer_secret     => $config->{app}{consumer_secret},
    );

    # request_token is passed back to us via the query string
    # as "oauth_token"...
    my $token = $req->query_parameters->{oauth_token}
        or return error( 400, 'No oauth_token' );

    # ... and the request_token_secret is stored in the browser cookie.
    my $token_secret = $req->cookies->{oauth_token_secret}
        or return error( 400, 'No oauth_token_secret cookie' );

    my $verifier = $req->query_parameters->{oauth_verifier}
        or return error( 400, 'No oauth_verifier' );

    $tp->oauth->request_token( $token );
    $tp->oauth->request_token_secret( $token_secret );

    # Given the request token, token secret, and verifier that TypePad
    # sent us, request an access token and secret that we can use for
    # future authenticated calls on behalf of this user.
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

    # Now store the user's person ID in the session.
    $req->session->{person_id} = $person->{person_id};

    my $res = Plack::Response->new;
    $res->redirect( $req->uri_for( '/' ) );

    # Remove the request token secret cookie that we created above.
    $res->cookies->{oauth_token_secret} = {
        value   => '',
        expires => time - 24 * 60 * 60,
    };

    return $res->finalize;    
};

my $logout = sub {
    my $req = Plack::Request->new( shift );

    # Kill the session.
    $req->env->{'psgix.session'} = {};

    my $res = Plack::Response->new;
    $res->redirect( $req->uri_for( '/' ) );
    return $res->finalize;
};

builder {
    my $secret = Tiptop::Util->config->{app}{session_secret};
    enable 'Session::Cookie', secret => $secret;

    mount '/static' => builder {
        Plack::App::File->new( { root => './static' } );
    };

    mount '/' => $dashboard;
    mount '/most' => $leaders;

    mount '/login' => $login;
    mount '/login-callback' => $login_cb;
    mount '/logout' => $logout;

    mount '/favicon.ico' => sub { return $error->( 404, "not found" ) };
};
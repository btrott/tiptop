#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use Tiptop::Util qw( debug );
use List::Util qw( first );
use WWW::TypePad;

my $tp = WWW::TypePad->new;
my $dbh = Tiptop::Util->get_dbh;
my $config = Tiptop::Util->config;

my $user_xid = $config->{user}{xid};
die "user.xid configuration is required; see README.markdown"
    unless defined $user_xid;

my $total;
my $i = 1;
my $most_recent_event_id;

my $user = $tp->users->get( $user_xid )
    or die "can't find user $user_xid on TypePad";
my $me_person = Tiptop::Util->find_or_create_person_from_api( $user );
my $me_person_id = $me_person->{person_id};

my( $last_event_id ) = $dbh->selectrow_array( <<SQL );
SELECT api_id FROM last_event_id
SQL

EVENTS: {
    do {
        my $res = $tp->users->notifications(
            $user_xid,
            { 'start-index' => $i }
        );
        $total ||= $res->{totalResults};
        $i += scalar @{ $res->{entries} };

        # The first time through the loop, set most_recent_event_id
        # to the api ID for the top event in the list (the most recent).
        # We'll set this in the DB after processing all events.
        $most_recent_event_id ||= $res->{entries}[0]{urlId};

        for my $event ( @{ $res->{entries} } ) {
            # Bail once we get to an event we've previously processed.
            last EVENTS if $last_event_id && $event->{urlId} eq $last_event_id;

            my $rv;

            # Process favorites...
            if ( is_favorite( $event ) ) {
                $rv = process_favorite( $event );
            }
            
            # ... and new assets ...
            elsif ( is_good_asset( $event ) ) {
                $rv = process_asset( $event );
            }

            # ... and skip everything else.
        }
    } while ( $i < $total );
}

if ( $most_recent_event_id ) {
    # TODO racy, but I don't care right now.
    if ( $last_event_id && $most_recent_event_id ne $last_event_id ) {
        $dbh->do( <<SQL, undef, $most_recent_event_id );
UPDATE last_event_id SET api_id = ?
SQL
    } elsif ( !$last_event_id ) {
        $dbh->do( <<SQL, undef, $most_recent_event_id );
INSERT INTO last_event_id (api_id) VALUES (?)
SQL
    }
}

exit;

sub is_good_asset {
    my( $event ) = @_;

    return unless is_verb( $event, 'tag:api.typepad.com,2009:NewAsset' );

    my $asset = $event->{object};

    # Skip comments.
    return if is_type( $asset, 'tag:api.typepad.com,2009:Comment' );

    # Skip non-Post assets unless they're in a Motion group.
    return unless
        is_type( $asset, 'tag:api.typepad.com,2009:Post' ) ||
        $asset->{groups} && @{ $asset->{groups} };

    return if $asset->{source} && $asset->{source}{provider};
    
    return 1;
}
            
sub is_favorite {
    my( $event ) = @_;
    return is_verb( $event, 'tag:api.typepad.com,2009:AddedFavorite' );
}

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

sub process_asset {
    my( $event ) = @_;
    return unless $event->{object};

    my $api_id = $event->{object}{urlId};
    my $row = $dbh->selectrow_arrayref( <<SQL, undef, $api_id );
SELECT 1 FROM asset WHERE api_id = ?
SQL
    if ( $row ) {
        debug "Already processed asset $api_id";
        return;
    }

    debug "Adding asset $api_id";

    # Convert the API objects into local objects, instantiating a local
    # record if we hadn't seen this asset before.
    my $asset = Tiptop::Util->find_or_create_asset_from_api( $event->{object} );

    $dbh->do( <<SQL, undef, $me_person_id, $asset->{asset_id} );
INSERT INTO stream (person_id, asset_id) VALUES (?, ?)
SQL
    
    return 1;
}

sub process_favorite {
    my( $event ) = @_;
    return unless $event->{object} && $event->{actor};

    my $fave_id = join ':', $event->{object}{urlId}, $event->{actor}{urlId};

    my $row = $dbh->selectrow_arrayref( <<SQL, undef, $fave_id );
SELECT 1 FROM favorited_by WHERE api_id = ?
SQL
    if ( $row ) {
        debug "Already processed favorite $fave_id";
        return;
    }

    debug "Adding favorite $fave_id";

    # Convert the API objects into local objects, instantiating a local
    # record if we hadn't seen this user/asset before.
    
    my $person = Tiptop::Util->find_or_create_person_from_api( $event->{actor} );
    my $asset = Tiptop::Util->find_or_create_asset_from_api( $event->{object} );

    $dbh->do( <<SQL, undef, $asset->{asset_id}, $person->{person_id}, $fave_id );
INSERT INTO favorited_by (asset_id, person_id, api_id) VALUES (?, ?, ?)
SQL

    $dbh->do( <<SQL, undef, $asset->{asset_id} );
UPDATE asset SET favorite_count = favorite_count + 1 WHERE asset_id = ?
SQL

    return 1;
}

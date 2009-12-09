DROP TABLE IF EXISTS asset;
CREATE TABLE asset (
    asset_id INTEGER UNSIGNED auto_increment NOT NULL,
    api_id VARCHAR(75) NOT NULL,
    person_id INTEGER UNSIGNED NOT NULL,
    title VARCHAR(255),
    content MEDIUMBLOB,
    permalink VARCHAR(255),
    created DATETIME,
    favorite_count INTEGER UNSIGNED,
    links_json MEDIUMBLOB,
    object_type VARCHAR(15),
    PRIMARY KEY (asset_id),
    INDEX (api_id),
    INDEX (person_id, created),
    INDEX (created),
    INDEX (favorite_count)
);

DROP TABLE IF EXISTS person;
CREATE TABLE person (
    person_id INTEGER UNSIGNED auto_increment NOT NULL,
    api_id VARCHAR(18) NOT NULL,
    display_name VARCHAR(100),
    avatar_uri VARCHAR(255),
    PRIMARY KEY (person_id),
    INDEX (api_id)
);

DROP TABLE IF EXISTS favorited_by;
CREATE TABLE favorited_by (
    asset_id INTEGER UNSIGNED NOT NULL,
    person_id INTEGER UNSIGNED NOT NULL,
    api_id VARCHAR(53) NOT NULL,
    INDEX (asset_id),
    UNIQUE (api_id)
);

DROP TABLE IF EXISTS last_event_id;
CREATE TABLE last_event_id (
    api_id varchar(34) NOT NULL
);

DROP TABLE IF EXISTS stream;
CREATE TABLE stream (
    person_id INTEGER UNSIGNED NOT NULL,
    asset_id INTEGER UNSIGNED NOT NULL,
    PRIMARY KEY (person_id, asset_id)
);
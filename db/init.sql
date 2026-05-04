
CREATE EXTENSION postgis;

-- Table for managing groups and subgroups of geometry data
CREATE TABLE meta (
    runid BIGSERIAL PRIMARY KEY,
    -- Which US State this metagroup is for
    state INT NOT NULL,
    -- type 0, level 0 represents the top level counties
    -- Number of layers to perform
    type INT NOT NULL,
    -- Previous metaid for referenccing higher layers
    previd BIGINT,
    -- Which layer of clustering this metagroup is, once it reaches `type`, it is complete
    level INT NOT NULL,
    -- Number of target elements within this metagroup
    size INT,
    -- Which election cycle this is from, null for higher order groupings
    election_year INT
);

CREATE INDEX meta_idx ON meta (runid, state);

-- Table for representing each outline
CREATE TABLE groups (
    groupid BIGSERIAL PRIMARY KEY,
    runid BIGINT NOT NULL,
    -- Actual outline geometry, could be grouped or not
    geo GEOMETRY(MultiPolygon, 4269) NOT NULL,
    -- Votes
    dem INT NOT NULL,
    rep INT NOT NULL,
    total INT NOT NULL,
    -- Reference the meta table to be discoverable
    FOREIGN KEY (runid) REFERENCES meta(runid)
);

CREATE INDEX groups_idx ON groups (groupid, runid);

-- Top level result group for final cluster results
CREATE TABLE result_group (
    resid BIGSERIAL PRIMARY KEY,
    -- Which layers were used for this clustering run
    layers INT[2][] NOT NULL,
    -- The group of original counties used for this clustering
    runid BIGINT NOT NULL,
    FOREIGN KEY (runid) REFERENCES meta(runid)
);

CREATE INDEX result_group_idx ON result_group (resid);

CREATE TABLE results (
    -- The runid of the top level grouping for the results
    runid BIGINT PRIMARY KEY,
    resid BIGINT NOT NULL,
    -- Seat counts
    dem INT NOT NULL,
    rep INT NOT NULL,
    total INT NOT NULL,
    FOREIGN KEY (runid) REFERENCES meta(runid),
    FOREIGN KEY (resid) REFERENCES result_group(resid)
);

CREATE INDEX results_idx ON results (runid, resid);

CREATE TABLE state_lookup (
    fips_code INT PRIMARY KEY,
    state_name VARCHAR(50) NOT NULL,
    abbreviation CHAR(2)
);

CREATE INDEX states_idx ON state_lookup (fips_code);

-- Define our state lookup table
INSERT INTO state_lookup (fips_code, state_name, abbreviation) VALUES
    (1, 'Alabama', 'AL'),
    (2, 'Alaska', 'AK'),
    (3, 'American Samoa', 'AS'),
    (4, 'Arizona', 'AZ'),
    (5, 'Arkansas', 'AR'),
    (6, 'California', 'CA'),
    (8, 'Colorado', 'CO'),
    (9, 'Connecticut', 'CT'),
    (10, 'Delaware', 'DE'),
    (11, 'District of Columbia', 'DC'),
    (12, 'Florida', 'FL'),
    (13, 'Georgia', 'GA'),
    (15, 'Hawaii', 'HI'),
    (16, 'Idaho', 'ID'),
    (17, 'Illinois', 'IL'),
    (18, 'Indiana', 'IN'),
    (19, 'Iowa', 'IA'),
    (20, 'Kansas', 'KS'),
    (21, 'Kentucky', 'KY'),
    (22, 'Louisiana', 'LA'),
    (23, 'Maine', 'ME'),
    (24, 'Maryland', 'MD'),
    (25, 'Massachusetts', 'MA'),
    (26, 'Michigan', 'MI'),
    (27, 'Minnesota', 'MN'),
    (28, 'Mississippi', 'MS'),
    (29, 'Missouri', 'MO'),
    (30, 'Montana', 'MT'),
    (31, 'Nebraska', 'NE'),
    (32, 'Nevada', 'NV'),
    (33, 'New Hampshire', 'NH'),
    (34, 'New Jersey', 'NJ'),
    (35, 'New Mexico', 'NM'),
    (36, 'New York', 'NY'),
    (37, 'North Carolina', 'NC'),
    (38, 'North Dakota', 'ND'),
    (39, 'Ohio', 'OH'),
    (40, 'Oklahoma', 'OK'),
    (41, 'Oregon', 'OR'),
    (42, 'Pennsylvania', 'PA'),
    (44, 'Rhode Island', 'RI'),
    (45, 'South Carolina', 'SC'),
    (46, 'South Dakota', 'SD'),
    (47, 'Tennessee', 'TN'),
    (48, 'Texas', 'TX'),
    (49, 'Utah', 'UT'),
    (50, 'Vermont', 'VT'),
    (51, 'Virginia', 'VA'),
    (53, 'Washington', 'WA'),
    (54, 'West Virginia', 'WV'),
    (55, 'Wisconsin', 'WI'),
    (56, 'Wyoming', 'WY'),
    (60, 'American Samoa', 'AS'),
    (64, 'Federated States of Micronesia', 'FM'),
    (66, 'Guam', 'GU'),
    (68, 'Marshall Islands', 'MH'),
    (69, 'Northern Mariana Islands', 'MP'),
    (70, 'Palau', 'PW'),
    (72, 'Puerto Rico', 'PR'),
    (74, 'U.S. Minor Outlying Islands', 'UM'),
    (78, 'Virgin Islands', 'VI');

CREATE OR REPLACE FUNCTION cluster_group(v_previd BIGINT, v_size INT, v_seed DOUBLE PRECISION, v_type INT DEFAULT -1)
RETURNS BIGINT AS $$
DECLARE
    v_runid BIGINT;
BEGIN
    if v_type = -1 then
        SELECT type-1 into v_type
        from meta
        where runid=v_previd;
    end if;

    INSERT INTO meta (state, type, previd, level, size) (
        SELECT
            state,
            v_type,
            v_previd,
            level + 1,
            v_size
        FROM meta
        WHERE runid=v_previd
    )
    RETURNING runid INTO v_runid;

    PERFORM setseed(v_seed);

    INSERT INTO groups (runid, dem, rep, total, geo) (
        SELECT
            v_runid,
            SUM(dem) AS dem,
            SUM(rep) AS rep,
            SUM(total) AS total,
            ST_CollectionExtract(ST_Union(geo)) AS geo
        FROM (
            SELECT 
                g.*,
                ST_ClusterKMeans(
                    ST_Force4D(
                        ST_Force3DZ(ST_GeneratePoints(g.geo, 1, (100000*random()+1)::INT), 0.15*random()),
                        mvalue => 1000*random()
                    ),
                    v_size
                ) OVER () AS clustering
            FROM groups AS g
            WHERE g.runid = v_previd
        )
        GROUP BY clustering
    );

    RETURN v_runid;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_layers(layers INT[2][], prevrunid BIGINT)
RETURNS BIGINT AS $$
DECLARE
    v_type INT;
    v_resid BIGINT;
BEGIN
    CREATE TEMP TABLE temp_runids (runid BIGINT);
    INSERT INTO temp_runids (runid) VALUES (prevrunid);

    v_type := array_length(layers, 1);

    FOR i IN 1..v_type
    LOOP
        CREATE TEMP TABLE temp_nextrunids (runid BIGINT);

        WITH runid_groups AS (
            SELECT runid FROM temp_runids
        )
        INSERT INTO temp_nextrunids (runid)
        SELECT
            cluster_group(runid_groups.runid, layers[i][1], count::double precision / layers[i][2], v_type)
        FROM runid_groups
        CROSS JOIN generate_series(1, layers[i][2]) AS count;

        TRUNCATE TABLE temp_runids;
        INSERT INTO temp_runids (runid)
        SELECT runid FROM temp_nextrunids;

        DROP TABLE temp_nextrunids;
    END LOOP;

    INSERT INTO result_group (layers, runid) VALUES (
        layers,
        prevrunid
    ) RETURNING resid INTO v_resid;

    INSERT INTO results (runid, resid, dem, rep, total) (
        SELECT
            groups.runid,
            v_resid,
            SUM(CASE WHEN dem > rep THEN 1 ELSE 0 END) AS dem,
            SUM(CASE WHEN rep > dem THEN 1 ELSE 0 END) AS rep,
            COUNT(total)
        FROM groups
        JOIN temp_runids ON temp_runids.runid = groups.runid
        GROUP BY groups.runid
    );

    return v_resid;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION initialize()
RETURNS VOID AS $$
BEGIN
    -- Create a unified temporary table for both years
    CREATE TEMP TABLE transformed_unified AS
        -- Pull 2020 Data
        SELECT
            2020 AS year,
            ST_Multi(ST_CollectionExtract(ST_MakeValid(
                -- Use ST_GeomFromEWKB to handle the PostGIS-specific format
                -- We wrap in ST_SetSRID(..., 4326) only if the EWKB SRID is 0
                ST_Transform(
                    CASE 
                        WHEN ST_SRID(ST_GeomFromEWKB(wkb_geometry)) = 0 
                        THEN ST_SetSRID(ST_GeomFromEWKB(wkb_geometry), 4326)
                        ELSE ST_GeomFromEWKB(wkb_geometry)
                    END, 
                    4269
                )
            ), 3))::geometry(MultiPolygon, 4269) AS geo,
            substring(geoid from 1 for 2)::INT AS state_id,
            substring(geoid from 3 for 3)::INT AS county_id,
            votes_dem AS dem,
            votes_rep AS rep,
            votes_total AS total
        FROM raw2020
        
        UNION ALL
        
        -- Pull 2024 Data
        SELECT
            2024 AS year,
            ST_Multi(ST_CollectionExtract(ST_MakeValid(
                ST_Transform(
                    CASE 
                        WHEN ST_SRID(ST_GeomFromEWKB(wkb_geometry)) = 0 
                        THEN ST_SetSRID(ST_GeomFromEWKB(wkb_geometry), 4326)
                        ELSE ST_GeomFromEWKB(wkb_geometry)
                    END, 
                    4269
                )
            ), 3))::geometry(MultiPolygon, 4269) AS geo,
            substring(geoid from 1 for 2)::INT AS state_id,
            substring(geoid from 3 for 3)::INT AS county_id,
            votes_dem AS dem,
            votes_rep AS rep,
            votes_total AS total
        FROM raw2024;

    -- Insert into meta (Level 0) for all years and states present
    INSERT INTO meta (state, type, level, election_year, size)
    SELECT state_id, 0, 0, year, COUNT(*)
    FROM transformed_unified
    GROUP BY state_id, year;

    -- Map shapes into groups, joining on state AND year to ensure correct lineage
    INSERT INTO groups (runid, geo, dem, rep, total)
    SELECT 
        m.runid, 
        t.geo, 
        COALESCE(t.dem, 0), 
        COALESCE(t.rep, 0), 
        COALESCE(t.total, 0)
    FROM transformed_unified AS t
    JOIN meta AS m ON (t.state_id = m.state AND t.year = m.election_year)
    WHERE m.level = 0;

    -- Insert the real county distribution from the dataset
    INSERT INTO meta (state, type, level, election_year, size, previd)
    SELECT m.state, 1, 1, m.election_year, 
           (SELECT COUNT(DISTINCT county_id) FROM transformed_unified WHERE state_id = m.state AND year = m.election_year),
           m.runid
    FROM meta m WHERE m.level = 0;

    -- Populate the group table with the actual merged county shapes
    INSERT INTO groups (runid, geo, dem, rep, total)
    SELECT 
        m_child.runid,
        ST_Multi(ST_Union(t.geo)), -- Merge all precincts in the same county
        SUM(t.dem),
        SUM(t.rep),
        SUM(t.total)
    FROM transformed_unified t
    JOIN meta m_parent ON (t.state_id = m_parent.state AND t.year = m_parent.election_year AND m_parent.level = 0)
    JOIN meta m_child ON (m_child.previd = m_parent.runid AND m_child.level = 1)
    GROUP BY m_child.runid, t.county_id;

    -- Cleanup
    DROP TABLE transformed_unified;
    DROP TABLE raw2020;
    DROP TABLE raw2024;
END;
$$ LANGUAGE plpgsql;
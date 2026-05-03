
CREATE EXTENSION postgis;

CREATE TABLE meta (
    runid BIGSERIAL PRIMARY KEY,
    state INT NOT NULL,
    type INT NOT NULL,
    previd INT,
    level INT NOT NULL,
    size INT
);

CREATE INDEX meta_idx ON meta (runid, state);

CREATE TABLE groups (
    groupid BIGSERIAL PRIMARY KEY,
    runid BIGINT NOT NULL,
    geo GEOMETRY NOT NULL,
    dem INT NOT NULL,
    rep INT NOT NULL,
    total INT NOT NULL,
    FOREIGN KEY (runid) REFERENCES meta(runid)
);

CREATE INDEX groups_idx ON groups (groupid, runid);

CREATE TABLE result_group (
    resid BIGSERIAL PRIMARY KEY,
    layers INT[2][] NOT NULL,
    runid BIGINT NOT NULL
);

CREATE INDEX result_group_idx ON result_group (resid);

CREATE TABLE results (
    runid BIGINT PRIMARY KEY,
    resid BIGINT NOT NULL,
    dem INT NOT NULL,
    rep INT NOT NULL,
    total INT NOT NULL,
    FOREIGN KEY (runid) REFERENCES meta(runid),
    FOREIGN KEY (resid) REFERENCES result_group(resid)
);

CREATE INDEX results_idx ON results (runid, resid);

CREATE FUNCTION cluster_group(v_previd BIGINT, v_size INT, v_seed DOUBLE PRECISION, v_type INT DEFAULT -1)
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
                        mvalue => 1000*random() -- set clustering to be weighed by population
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

CREATE FUNCTION create_layers(layers INT[2][], prevrunid BIGINT)
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

CREATE FUNCTION initialize()
RETURNS VOID
AS $$
BEGIN
    CREATE TABLE transformed AS
    SELECT
        ogc_fid AS id,
        ST_CollectionExtract(ST_MakeValid(ST_GeomFromWKB(wkb_geometry))) AS geo,
        substring(geoid from 1 for 2)::INT AS state,
        substring(geoid from 3 for 3)::INT AS county,
        votes_dem AS dem,
        votes_rep AS rep,
        votes_total AS total
    from jerry;

    INSERT INTO meta (state, type, level)
        SELECT state, 0, 0
        FROM transformed
        GROUP BY state;

    INSERT INTO groups (runid, geo, dem, rep, total)
        SELECT m.runid, t.geo, COALESCE(t.dem, 0), COALESCE(t.rep, 0), COALESCE(t.total, 0)
        FROM transformed AS t
        JOIN meta AS m ON t.state = m.state;
END;
$$ LANGUAGE plpgsql

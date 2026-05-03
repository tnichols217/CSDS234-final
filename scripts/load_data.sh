#/usr/bin/env bash

ogr2ogr -f "PostgreSQL" PG:"host=$POSTGRES_ENDPOINT dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD" ./data/2020-precincts-with-results.geojson -nln raw2020 -nlt PROMOTE_TO_MULTI

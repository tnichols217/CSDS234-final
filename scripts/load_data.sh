#!/usr/bin/env bash

echo "Loading 2020 Data..."
ogr2ogr -f "PostgreSQL" PG:"host=$POSTGRES_ENDPOINT port=$POSTGRES_PORT dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD" ./data/2020-precincts-with-results.geojson -nln raw2020 -nlt PROMOTE_TO_MULTI -progress

echo "Loading 2024 Data..."
ogr2ogr -f "PostgreSQL" PG:"host=$POSTGRES_ENDPOINT port=$POSTGRES_PORT dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD" ./data/2024-precincts-with-results.topojson -nln raw2024 -nlt PROMOTE_TO_MULTI -progress

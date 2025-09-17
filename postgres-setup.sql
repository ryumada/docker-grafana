-- Step 1: connect as a privileged user (e.g., postgres superuser)
-- psql -h <host> -U postgres

-- Step 2: create a dedicated role with just LOGIN and CREATEDB
CREATE ROLE grafana_profile WITH LOGIN CREATEDB PASSWORD 'change_me';

-- Step 3: create the database owned by the Grafana role
CREATE DATABASE grafana_data OWNER grafana_profile;

-- Step 4 (optional): restrict privileges further if desired
-- REVOKE ALL ON DATABASE grafana_data FROM PUBLIC;

------------------------------------------------------------------
-- PARTIE 2 : MODELISTATION ET TRANSFORMATION (POSTGRESQL)
------------------------------------------------------------------

-- 1. Création du schéma
CREATE SCHEMA IF NOT EXISTS analytics_furcy_goncalves;

------------------------------------------------------------------
-- 2. COUCHE SILVER : TABLES NETTOYÉES
-- Objectif : nettoyer, typer et standardiser les données brutes
------------------------------------------------------------------

------------------------------
-- 2.1. user_accounts
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_user_accounts;

CREATE TABLE analytics_furcy_goncalves.silver_user_accounts AS
SELECT
    ua.user_id,

    CASE
        WHEN ua.birthdate IS NULL THEN NULL
        -- plus de 100 ans
        WHEN ua.birthdate::date < (CURRENT_DATE - INTERVAL '100 years') THEN NULL
        -- date de naissance dans le futur
        WHEN ua.birthdate::date > CURRENT_DATE THEN NULL
        -- date de naissance postérieure à l'inscription
        WHEN ua.birthdate::date > ua.registration_date::date THEN NULL
        ELSE ua.birthdate::date
    END AS birthdate,

    ua.registration_date::date AS registration_date,
    ua.subscription_id

FROM raw.user_accounts ua
WHERE ua.user_id IS NOT NULL
  AND ua.email IS NOT NULL
  -- on élimine les inscriptions futures
  AND ua.registration_date::date <= CURRENT_DATE;

-- Index pour l'accès analytique
CREATE INDEX IF NOT EXISTS idx_silver_user_accounts_user_id
    ON analytics_furcy_goncalves.silver_user_accounts(user_id);


------------------------------
-- 2.2. subscriptions
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_subscriptions;

CREATE TABLE analytics_furcy_goncalves.silver_subscriptions AS
SELECT
    LOWER(s.subscription_id) AS subscription_id,
    s.sub_name,

   -- Nettoyage et typage du prix
    CASE
        WHEN s.price IS NULL THEN NULL
        ELSE REPLACE(
                REPLACE(
                    REPLACE(s.price, '€', ''),
                ' ', ''),
            ',', '.')::numeric(10,2)
    END AS price,

    -- Normalisation de la devise
    CASE
        WHEN s.currency IN ('EUR', '€', 'Euro') THEN 'EUR'
        WHEN s.currency = 'GBP' THEN 'GBP'
        WHEN s.currency IS NULL AND s.price = '0.00' THEN 'FREE'
        ELSE 'UNKNOWN'
    END AS currency,

    s.country_scope,

    s.start_date::date AS start_date,
    s.end_date::date   AS end_date

FROM raw.subscriptions s
WHERE s.subscription_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_silver_subscriptions_id
    ON analytics_furcy_goncalves.silver_subscriptions(subscription_id);


------------------------------
-- 2.3. bikes
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_bikes;

CREATE TABLE analytics_furcy_goncalves.silver_bikes AS
SELECT
    b.bike_id,
    b.bike_type,
    b.model_name,
    (b.commissioning_date)::date AS commissioning_date,
    b.status
FROM raw.bikes b
WHERE b.bike_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_silver_bikes_id
    ON analytics_furcy_goncalves.silver_bikes(bike_id);


------------------------------
-- 2.4. bike_stations
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_bike_stations;

CREATE TABLE analytics_furcy_goncalves.silver_bike_stations AS
SELECT
    bs.station_id,
    bs.station_name,
    CASE
        WHEN REGEXP_REPLACE(bs.latitude, '[^0-9,\.]', '', 'g') <> ''
        THEN REPLACE(REGEXP_REPLACE(bs.latitude, '[^0-9,\.]', '', 'g'), ',', '.')::numeric(10,6)
        ELSE NULL
    END AS latitude,

    CASE
        WHEN REGEXP_REPLACE(bs.longitude, '[^0-9,\.]', '', 'g') <> ''
        THEN REPLACE(REGEXP_REPLACE(bs.longitude, '[^0-9,\.]', '', 'g'), ',', '.')::numeric(10,6)
        ELSE NULL
    END AS longitude,
    (bs.capacity)::integer        AS capacity,
    bs.city_id
FROM raw.bike_stations bs
WHERE bs.station_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_silver_bike_stations_id
    ON analytics_furcy_goncalves.silver_bike_stations(station_id);

CREATE INDEX IF NOT EXISTS idx_silver_bike_stations_city
    ON analytics_furcy_goncalves.silver_bike_stations(city_id);


------------------------------
-- 2.5. cities
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_cities;

CREATE TABLE analytics_furcy_goncalves.silver_cities AS
SELECT
    c.city_id,
    c.city_name,
    c.region,
    c.country
FROM raw.cities c
WHERE c.city_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_silver_cities_id
    ON analytics_furcy_goncalves.silver_cities(city_id);


------------------------------
-- 2.6. bike_rentals
------------------------------
-- Table de faits des trajets
-- On calcule la durée en minutes et on filtre les trajets aberrants
------------------------------
DROP TABLE IF EXISTS analytics_furcy_goncalves.silver_bike_rentals;

CREATE TABLE analytics_furcy_goncalves.silver_bike_rentals AS
WITH rentals_cast AS (
    SELECT
        br.rental_id,
        br.bike_id,
        br.user_id,
        br.start_station_id,
        br.end_station_id,
        CASE
            WHEN br.start_t LIKE '%/%'
                THEN to_timestamp(br.start_t, 'DD/MM/YYYY HH24:MI:SS')
            WHEN br.start_t LIKE '%-%'
                THEN to_timestamp(br.start_t, 'YYYY-MM-DD HH24:MI:SS')
            ELSE NULL
        END AS start_ts,

        CASE
            WHEN br.end_t LIKE '%/%'
                THEN to_timestamp(br.end_t, 'DD/MM/YYYY HH24:MI:SS')
            WHEN br.end_t LIKE '%-%'
                THEN to_timestamp(br.end_t, 'YYYY-MM-DD HH24:MI:SS')
            ELSE NULL
        END AS end_ts
    FROM raw.bike_rentals br
    WHERE br.rental_id IS NOT NULL
)
SELECT
    r.rental_id,
    r.bike_id,
    r.user_id,
    r.start_station_id,
    r.end_station_id,
    r.start_ts,
    r.end_ts,
    -- durée en minutes
    EXTRACT(EPOCH FROM (r.end_ts - r.start_ts)) / 60.0 AS duration_minutes
FROM rentals_cast r
WHERE
    -- on enlève les trajets tests ou avortés : durée < 2 minutes
    EXTRACT(EPOCH FROM (r.end_ts - r.start_ts)) / 60.0 >= 2
    -- on enlève aussi les durées négatives éventuelles
    AND r.end_ts >= r.start_ts;

CREATE INDEX IF NOT EXISTS idx_silver_bike_rentals_rental_id
    ON analytics_furcy_goncalves.silver_bike_rentals(rental_id);

CREATE INDEX IF NOT EXISTS idx_silver_bike_rentals_start_ts
    ON analytics_furcy_goncalves.silver_bike_rentals(start_ts);

CREATE INDEX IF NOT EXISTS idx_silver_bike_rentals_user_id
    ON analytics_furcy_goncalves.silver_bike_rentals(user_id);

CREATE INDEX IF NOT EXISTS idx_silver_bike_rentals_bike_id
    ON analytics_furcy_goncalves.silver_bike_rentals(bike_id);

CREATE INDEX IF NOT EXISTS idx_silver_bike_rentals_start_station
    ON analytics_furcy_goncalves.silver_bike_rentals(start_station_id);


------------------------------------------------------------------
-- 3) COUCHE GOLD : TABLE METIER POUR LE DASHBOARD gold_daily_activity
-- Objectif : par jour, par ville, par station, par type de vélo et par abonnement :
--           - total_rentals
--           - average_duration_minutes
--           - unique_users
------------------------------------------------------------------

DROP TABLE IF EXISTS analytics_furcy_goncalves.gold_daily_activity;

CREATE TABLE analytics_furcy_goncalves.gold_daily_activity AS
SELECT
    -- granularité jour
    DATE_TRUNC('day', r.start_ts)::date AS activity_date,
    c.city_name                         AS city_name,
    bs.station_name                     AS station_name,
    b.bike_type                         AS bike_type,
    s.sub_name                 AS sub_name,

    -- métriques demandées
    COUNT(*)                            AS total_rentals,
    AVG(r.duration_minutes)             AS average_duration_minutes,
    COUNT(DISTINCT r.user_id)           AS unique_users

FROM analytics_furcy_goncalves.silver_bike_rentals    r
JOIN analytics_furcy_goncalves.silver_user_accounts   ua
     ON r.user_id = ua.user_id
JOIN analytics_furcy_goncalves.silver_subscriptions   s
     ON ua.subscription_id = s.subscription_id
JOIN analytics_furcy_goncalves.silver_bikes           b
     ON r.bike_id = b.bike_id
JOIN analytics_furcy_goncalves.silver_bike_stations   bs
     ON r.start_station_id = bs.station_id
JOIN analytics_furcy_goncalves.silver_cities          c
     ON bs.city_id = c.city_id

GROUP BY
    DATE_TRUNC('day', r.start_ts)::date,
    c.city_name,
    bs.station_name,
    b.bike_type,
    s.sub_name;

-- Index utile pour les requêtes temps + ville
CREATE INDEX IF NOT EXISTS idx_gold_daily_activity_date_city
    ON analytics_furcy_goncalves.gold_daily_activity(activity_date, city_name);


------------------------------------------------------------------
-- PARTIE 4 : SECURITE ET GOUVERNANCE
-- 4.1 Rôle marketing_user (accès uniquement à la table GOLD)
------------------------------------------------------------------

-- Création du rôle marketing_user
CREATE ROLE marketing_user LOGIN PASSWORD 'changeme';

-- Retrait des droits sur les schémas raw et analytics_furcy_goncalves
REVOKE ALL ON SCHEMA raw FROM marketing_user;
REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM marketing_user;

REVOKE ALL ON SCHEMA analytics_furcy_goncalves FROM marketing_user;
REVOKE ALL ON ALL TABLES IN SCHEMA analytics_furcy_goncalves FROM marketing_user;

-- Autorisation de base sur le schéma analytics
GRANT USAGE ON SCHEMA analytics_furcy_goncalves TO marketing_user;

-- Droit de lecture uniquement sur la table GOLD
GRANT SELECT ON TABLE analytics_furcy_goncalves.gold_daily_activity
TO marketing_user;


------------------------------------------------------------------
-- 4.2 Rôle manager_lyon + Row Level Security (RLS) sur GOLD
------------------------------------------------------------------

-- Création du rôle manager_lyon
CREATE ROLE manager_lyon LOGIN PASSWORD 'mgl';

-- Autorisation de base sur le schéma et la table GOLD
GRANT USAGE ON SCHEMA analytics_furcy_goncalves TO manager_lyon;
GRANT SELECT ON TABLE analytics_furcy_goncalves.gold_daily_activity
TO manager_lyon;

-- Activation de la RLS sur la table GOLD
ALTER TABLE analytics_furcy_goncalves.gold_daily_activity
ENABLE ROW LEVEL SECURITY;

-- On supprime la policy si elle existe déjà (pour éviter les erreurs si on relance le script)
DROP POLICY IF EXISTS lyon_only
ON analytics_furcy_goncalves.gold_daily_activity;

-- Policy : manager_lyon ne voit que les lignes de Lyon
CREATE POLICY lyon_only
ON analytics_furcy_goncalves.gold_daily_activity
FOR SELECT
TO manager_lyon
USING (city_name = 'Lyon');

-- Policy RLS pour marketing_user : accès à toutes les lignes (sinon il voit 0 ligne)
DROP POLICY IF EXISTS marketing_all
ON analytics_furcy_goncalves.gold_daily_activity;

CREATE POLICY marketing_all
ON analytics_furcy_goncalves.gold_daily_activity
FOR SELECT
TO marketing_user
USING (true);
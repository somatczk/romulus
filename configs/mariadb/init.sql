-- MariaDB Initialization Script
-- Homeserver Infrastructure Database Setup
-- 
-- Purpose: Initialize databases and users for homeserver services
-- Services: TeamSpeak 3, Application data
-- 
-- Security: Uses environment variables for passwords
-- Performance: Optimized for SSD storage with InnoDB

-- Create TeamSpeak 3 database (already created by docker-compose environment)
-- The main teamspeak database is created automatically via MYSQL_DATABASE


-- Create database for application logs and metadata
CREATE DATABASE IF NOT EXISTS `homeserver_logs` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create read-only user for monitoring/backup services
CREATE USER IF NOT EXISTS 'monitoring'@'%' IDENTIFIED BY '${MONITORING_DB_PASSWORD}';
GRANT SELECT ON *.* TO 'monitoring'@'%';
GRANT PROCESS ON *.* TO 'monitoring'@'%';
GRANT REPLICATION CLIENT ON *.* TO 'monitoring'@'%';

-- Create backup user with specific privileges
CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY '${BACKUP_DB_PASSWORD}';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup'@'%';

-- TeamSpeak 3 specific optimizations
-- The teamspeak database is created automatically, but we can add indexes for better performance

-- Verify TeamSpeak database exists and add optimizations if needed
USE `teamspeak`;

-- Add indexes for common TeamSpeak queries (if tables exist)
-- Note: TeamSpeak will create its own schema, these are potential optimizations

-- Create a simple health check table for monitoring
CREATE TABLE IF NOT EXISTS `health_check` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `status` varchar(20) NOT NULL DEFAULT 'healthy',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert initial health check record
INSERT INTO `health_check` (`status`) VALUES ('initialized') ON DUPLICATE KEY UPDATE `timestamp` = CURRENT_TIMESTAMP;

-- Create application logs table for centralized logging
USE `homeserver_logs`;

CREATE TABLE IF NOT EXISTS `application_logs` (
    `id` bigint(20) NOT NULL AUTO_INCREMENT,
    `timestamp` timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `service_name` varchar(50) NOT NULL,
    `level` enum('DEBUG','INFO','WARN','ERROR','FATAL') NOT NULL DEFAULT 'INFO',
    `message` text NOT NULL,
    `metadata` json DEFAULT NULL,
    `host` varchar(100) DEFAULT NULL,
    `container_id` varchar(64) DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_timestamp` (`timestamp`),
    KEY `idx_service_level` (`service_name`, `level`),
    KEY `idx_level_timestamp` (`level`, `timestamp`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create system metrics table for custom application metrics
CREATE TABLE IF NOT EXISTS `system_metrics` (
    `id` bigint(20) NOT NULL AUTO_INCREMENT,
    `timestamp` timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `metric_name` varchar(100) NOT NULL,
    `metric_value` decimal(20,6) NOT NULL,
    `labels` json DEFAULT NULL,
    `service_name` varchar(50) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_metric_timestamp` (`metric_name`, `timestamp`),
    KEY `idx_service_timestamp` (`service_name`, `timestamp`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create service status tracking table
CREATE TABLE IF NOT EXISTS `service_status` (
    `service_name` varchar(50) NOT NULL,
    `status` enum('healthy','degraded','unhealthy','unknown') NOT NULL DEFAULT 'unknown',
    `last_check` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `details` json DEFAULT NULL,
    `uptime_seconds` bigint(20) DEFAULT 0,
    PRIMARY KEY (`service_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert initial service status records
INSERT INTO `service_status` (`service_name`, `status`) VALUES 
    ('caddy', 'unknown'),
    ('plex', 'unknown'),
    ('qbittorrent', 'unknown'),
    ('teamspeak', 'unknown'),
    ('cs2-server', 'unknown'),
    ('prometheus', 'unknown'),
    ('grafana', 'unknown'),
    ('loki', 'unknown'),
    ('mariadb', 'healthy')
ON DUPLICATE KEY UPDATE `last_check` = CURRENT_TIMESTAMP;

-- Create stored procedure for service health updates
DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS UpdateServiceStatus(
    IN service_name_param VARCHAR(50),
    IN status_param ENUM('healthy','degraded','unhealthy','unknown'),
    IN details_param JSON
)
BEGIN
    INSERT INTO `service_status` (`service_name`, `status`, `details`, `last_check`) 
    VALUES (service_name_param, status_param, details_param, CURRENT_TIMESTAMP)
    ON DUPLICATE KEY UPDATE 
        `status` = status_param,
        `details` = details_param,
        `last_check` = CURRENT_TIMESTAMP;
END$$

DELIMITER ;

-- Create cleanup procedure for old logs (retention policy)
DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS CleanupOldLogs()
BEGIN
    -- Delete application logs older than 30 days
    DELETE FROM `application_logs` WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL 30 DAY);
    
    -- Delete system metrics older than 90 days
    DELETE FROM `system_metrics` WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL 90 DAY);
    
    -- Update service status to unknown for services not checked in 5 minutes
    UPDATE `service_status` 
    SET `status` = 'unknown' 
    WHERE `last_check` < DATE_SUB(NOW(), INTERVAL 5 MINUTE) 
    AND `status` != 'unknown';
END$$

DELIMITER ;

-- Grant necessary privileges for the cleanup procedure
GRANT EXECUTE ON PROCEDURE `homeserver_logs`.`CleanupOldLogs` TO 'monitoring'@'%';
GRANT EXECUTE ON PROCEDURE `homeserver_logs`.`UpdateServiceStatus` TO 'monitoring'@'%';

-- Flush privileges to ensure all changes take effect
FLUSH PRIVILEGES;

-- Final status message
SELECT 'MariaDB initialization completed successfully' as status;
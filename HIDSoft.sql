-- MySQL dump 10.19  Distrib 10.3.39-MariaDB, for Linux (x86_64)
--
-- Host: localhost    Database: HIDSoft
-- ------------------------------------------------------
-- Server version       10.3.39-MariaDB

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `HIDActive`
--

DROP TABLE IF EXISTS `HIDActive`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDActive` (
  `mac` varchar(64) NOT NULL,
  `ip` varchar(64) DEFAULT NULL,
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `identdb` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `accessdb` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  PRIMARY KEY (`mac`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDAlarm`
--

DROP TABLE IF EXISTS `HIDAlarm`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDAlarm` (
  `id` tinyint(4) NOT NULL,
  `alarm` tinyint(4) NOT NULL,
  `cmd` tinyint(4) NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDCalendar`
--

DROP TABLE IF EXISTS `HIDCalendar`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDCalendar` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  `schid` int(2) DEFAULT NULL,
  `caldate` date NOT NULL,
  `comment` varchar(255) DEFAULT NULL,
  `added` timestamp NOT NULL DEFAULT current_timestamp(),
  `lastupdate` timestamp NULL DEFAULT NULL,
  `deleted` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `HIDCalendar`
--

LOCK TABLES `HIDCalendar` WRITE;
/*!40000 ALTER TABLE `HIDCalendar` DISABLE KEYS */;
INSERT INTO `HIDCalendar` VALUES (1,'Initial Entry',1,'2020-06-23','Initial Setup','2020-06-23 19:34:56','2020-06-23 19:34:56',NULL);
/*!40000 ALTER TABLE `HIDCalendar` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `HIDCards`
--

DROP TABLE IF EXISTS `HIDCards`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDCards` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `contact_id` int(11) DEFAULT NULL,
  `firstname` varchar(50) DEFAULT NULL,
  `lastname` varchar(50) DEFAULT NULL,
  `name` varchar(255) DEFAULT NULL,
  `regnum` bigint(12) DEFAULT NULL,
  `company` varchar(50) DEFAULT NULL,
  `groupid` int(5) NOT NULL,
  `cardnum` varchar(40) NOT NULL,
  `access` tinyint(1) DEFAULT 0,
  `created` timestamp NOT NULL DEFAULT current_timestamp(),
  `expires` timestamp NULL DEFAULT NULL,
  `deleted` timestamp NULL DEFAULT NULL,
  `lastupdate` timestamp NULL DEFAULT NULL,
  `is_third_party` tinyint(1) NOT NULL DEFAULT 0,
  `photo` varchar(64) NOT NULL DEFAULT 'no_photo.png',
  `photo_width` int(11) NOT NULL DEFAULT 200,
  `photo_height` int(11) NOT NULL DEFAULT 230,
  `westin_access` int(2) DEFAULT NULL,
  `westin_mmr` int(2) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `cardnum_index` (`cardnum`),
  KEY `contact_id` (`contact_id`)
) ENGINE=MyISAM AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDGroups`
--

DROP TABLE IF EXISTS `HIDGroups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDGroups` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `added` timestamp NOT NULL DEFAULT current_timestamp(),
  `lastupdate` timestamp NULL DEFAULT NULL,
  `deleted` timestamp NULL DEFAULT NULL,
  `comment` varchar(255) DEFAULT NULL,
  `location` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDHoliday`
--

DROP TABLE IF EXISTS `HIDHoliday`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDHoliday` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `schid` int(11) NOT NULL DEFAULT 1,
  `stime1` time NOT NULL DEFAULT '00:00:00',
  `etime1` time NOT NULL DEFAULT '00:00:00',
  `stime2` time DEFAULT NULL,
  `etime2` time DEFAULT NULL,
  `comment` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `added` timestamp NOT NULL DEFAULT current_timestamp(),
  `lastupdate` timestamp NULL DEFAULT NULL,
  `deleted` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `HIDHoliday`
--

LOCK TABLES `HIDHoliday` WRITE;
/*!40000 ALTER TABLE `HIDHoliday` DISABLE KEYS */;
INSERT INTO `HIDHoliday` VALUES (1,'All Locked',1,'00:00:00','00:00:00',NULL,NULL,'Keep Door locked on Holidays','2020-06-22 09:52:20',NULL,NULL);
/*!40000 ALTER TABLE `HIDHoliday` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `HIDLocations`
--

DROP TABLE IF EXISTS `HIDLocations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDLocations` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `address` varchar(255) DEFAULT NULL,
  `comment` varchar(255) DEFAULT NULL,
  `added` timestamp NOT NULL DEFAULT current_timestamp(),
  `lastupdate` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `deleted` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDLog`
--

DROP TABLE IF EXISTS `HIDLog`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDLog` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `taskcode` varchar(32) DEFAULT NULL,
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `reader` varchar(20) NOT NULL,
  `message` varchar(480) NOT NULL,
  `handled` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `taskcode` (`taskcode`),
  KEY `timestamp` (`timestamp`),
  KEY `handled` (`handled`),
  KEY `taskcode_id` (`taskcode`,`id`),
  KEY `timestamp_taskcode` (`timestamp`,`taskcode`),
  KEY `taskcode_message` (`taskcode`,`message`)
) ENGINE=MyISAM AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDReaders`
--

DROP TABLE IF EXISTS `HIDReaders`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDReaders` (
  `id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID of the reader',
  `mac` varchar(20) NOT NULL COMMENT 'MAC address of the reader',
  `ip` varchar(18) DEFAULT NULL,
  `groups_allowed` varchar(60) DEFAULT '10',
  `groups` varchar(100) DEFAULT NULL,
  `name` varchar(255) DEFAULT NULL,
  `comment` varchar(60) DEFAULT NULL,
  `pass` varchar(60) DEFAULT NULL,
  `qentry` int(1) NOT NULL DEFAULT 0,
  `ftp` int(1) DEFAULT 0,
  `failcount` int(1) DEFAULT 0,
  `schid` varchar(255) DEFAULT '1',
  `holid` varchar(255) DEFAULT '1',
  `manual_open` smallint(3) DEFAULT 0,
  `cmd` varchar(10) NOT NULL DEFAULT '0',
  `order` int(11) NOT NULL DEFAULT 0,
  `Deleted` timestamp NULL DEFAULT NULL,
  `lasttimesync` timestamp NOT NULL DEFAULT current_timestamp(),
  `changeover` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `added` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `lastupdate` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  PRIMARY KEY (`id`),
  UNIQUE KEY `mac` (`mac`)
) ENGINE=MyISAM AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDSchedule`
--

DROP TABLE IF EXISTS `HIDSchedule`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDSchedule` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `monstime` time NOT NULL DEFAULT '00:00:00',
  `monetime` time NOT NULL DEFAULT '00:00:00',
  `tuestime` time NOT NULL DEFAULT '00:00:00',
  `tueetime` time NOT NULL DEFAULT '00:00:00',
  `wedstime` time NOT NULL DEFAULT '00:00:00',
  `wedetime` time NOT NULL DEFAULT '00:00:00',
  `thustime` time NOT NULL DEFAULT '00:00:00',
  `thuetime` time NOT NULL DEFAULT '00:00:00',
  `fristime` time NOT NULL DEFAULT '00:00:00',
  `frietime` time NOT NULL DEFAULT '00:00:00',
  `satstime` time NOT NULL DEFAULT '00:00:00',
  `satetime` time NOT NULL DEFAULT '00:00:00',
  `sunstime` time NOT NULL DEFAULT '00:00:00',
  `sunetime` time NOT NULL DEFAULT '00:00:00',
  `comment` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL,
  `added` timestamp NOT NULL DEFAULT current_timestamp(),
  `lastupdate` timestamp NULL DEFAULT NULL,
  `deleted` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

LOCK TABLES `HIDSchedule` WRITE;
/*!40000 ALTER TABLE `HIDSchedule` DISABLE KEYS */;
INSERT INTO `HIDSchedule` VALUES (1,'Always Locked','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','00:00:00','Always Locked','2020-02-01 20:34:56','2020-06-12 22:36:38',NULL),(2,'Always Open','00:00:00','23:59:59','00:00:00','23:59:59','00:00:00','23:59:59','00:00:00','23:59:59','00:00:00','23:59:59','00:00:00','23:59:59','00:00:00','23:59:59','Always Open','2020-02-02 04:34:56',NULL,NULL);
/*!40000 ALTER TABLE `HIDSchedule` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

--
-- Table structure for table `HIDSoftChanges`
--

DROP TABLE IF EXISTS `HIDSoftChanges`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDSoftChanges` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `message` text DEFAULT NULL,
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `HIDSoftLog`
--

DROP TABLE IF EXISTS `HIDSoftLog`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `HIDSoftLog` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `device` varchar(20) NOT NULL,
  `message` varchar(255) NOT NULL,
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `type` int(2) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_type_timestamp` (`type`,`timestamp`),
  KEY `idx_type_id` (`type`,`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-07-21 11:31:31
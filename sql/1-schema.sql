SET CHARACTER_SET_CLIENT = utf8mb4;
SET CHARACTER_SET_CONNECTION = utf8mb4;

USE isuride;

DROP TABLE IF EXISTS settings;
CREATE TABLE settings
(
  name  VARCHAR(30) NOT NULL COMMENT '設定名',
  value TEXT        NOT NULL COMMENT '設定値',
  PRIMARY KEY (name)
)
  COMMENT = 'システム設定テーブル';

DROP TABLE IF EXISTS chair_models;
CREATE TABLE chair_models
(
  name  VARCHAR(50) NOT NULL COMMENT '椅子モデル名',
  speed INTEGER     NOT NULL COMMENT '移動速度',
  PRIMARY KEY (name)
)
  COMMENT = '椅子モデルテーブル';

DROP TABLE IF EXISTS chairs;
CREATE TABLE chairs
(
  id                        VARCHAR(26)  NOT NULL COMMENT '椅子ID',
  owner_id                  VARCHAR(26)  NOT NULL COMMENT 'オーナーID',
  name                      VARCHAR(30)  NOT NULL COMMENT '椅子の名前',
  model                     TEXT         NOT NULL COMMENT '椅子のモデル',
  speed                     INT          NOT NULL,
  is_active                 TINYINT(1)   NOT NULL COMMENT '配椅子受付中かどうか',
  current_ride_id           VARCHAR(26) DEFAULT NULL,
  access_token              VARCHAR(255) NOT NULL COMMENT 'アクセストークン',
  created_at                DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '登録日時',
  updated_at                DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6) COMMENT '更新日時',
  latitude                  INT,
  longitude                 INT,
  total_distance            INT          NOT NULL DEFAULT '0',
  total_distance_updated_at DATETIME(6),
  total_rides_count         INT          NOT NULL DEFAULT 0,
  total_evaluation          INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
)
  COMMENT = '椅子情報テーブル';

DROP TABLE IF EXISTS users;
CREATE TABLE users
(
  id              VARCHAR(26)  NOT NULL COMMENT 'ユーザーID',
  username        VARCHAR(30)  NOT NULL COMMENT 'ユーザー名',
  firstname       VARCHAR(30)  NOT NULL COMMENT '本名(名前)',
  lastname        VARCHAR(30)  NOT NULL COMMENT '本名(名字)',
  date_of_birth   VARCHAR(30)  NOT NULL COMMENT '生年月日',
  access_token    VARCHAR(255) NOT NULL COMMENT 'アクセストークン',
  invitation_code VARCHAR(30)  NOT NULL COMMENT '招待トークン',
  created_at      DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '登録日時',
  updated_at      DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6) COMMENT '更新日時',
  current_ride_id VARCHAR(26)  DEFAULT NULL,
  ride_count      INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE (username),
  UNIQUE (access_token),
  UNIQUE (invitation_code)
)
  COMMENT = '利用者情報テーブル';

DROP TABLE IF EXISTS payment_tokens;
CREATE TABLE payment_tokens
(
  user_id    VARCHAR(26)  NOT NULL COMMENT 'ユーザーID',
  token      VARCHAR(255) NOT NULL COMMENT '決済トークン',
  created_at DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '登録日時',
  PRIMARY KEY (user_id)
)
  COMMENT = '決済トークンテーブル';

DROP TABLE IF EXISTS rides;
CREATE TABLE rides
(
  id                    VARCHAR(26)      NOT NULL           COMMENT 'ライドID',
  user_id               VARCHAR(26)      NOT NULL           COMMENT 'ユーザーID',
  chair_id              VARCHAR(26)      NULL               COMMENT '割り当てられた椅子ID',
  pickup_latitude       INTEGER          NOT NULL           COMMENT '配車位置(経度)',
  pickup_longitude      INTEGER          NOT NULL           COMMENT '配車位置(緯度)',
  destination_latitude  INTEGER          NOT NULL           COMMENT '目的地(経度)',
  destination_longitude INTEGER          NOT NULL           COMMENT '目的地(緯度)',
  evaluation            INTEGER          NULL               COMMENT '評価',
  fare                  INTEGER UNSIGNED NOT NULL DEFAULT 0 COMMENT '運賃',
  created_at            DATETIME(6)      NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '要求日時',
  updated_at            DATETIME(6)      NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6) COMMENT '状態更新日時',
  status                VARCHAR(255)     NOT NULL DEFAULT 'MATCHING',
  PRIMARY KEY (id)
)
  COMMENT = 'ライド情報テーブル';

DROP TABLE IF EXISTS owners;
CREATE TABLE owners
(
  id                   VARCHAR(26)  NOT NULL COMMENT 'オーナーID',
  name                 VARCHAR(30)  NOT NULL COMMENT 'オーナー名',
  access_token         VARCHAR(255) NOT NULL COMMENT 'アクセストークン',
  chair_register_token VARCHAR(255) NOT NULL COMMENT '椅子登録トークン',
  created_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '登録日時',
  updated_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6) COMMENT '更新日時',
  PRIMARY KEY (id),
  UNIQUE (name),
  UNIQUE (access_token),
  UNIQUE (chair_register_token)
)
  COMMENT = '椅子のオーナー情報テーブル';

DROP TABLE IF EXISTS coupons;
CREATE TABLE coupons
(
  user_id    VARCHAR(26)  NOT NULL COMMENT '所有しているユーザーのID',
  code       VARCHAR(255) NOT NULL COMMENT 'クーポンコード',
  discount   INTEGER      NOT NULL COMMENT '割引額',
  created_at DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '付与日時',
  used_by    VARCHAR(26)  NULL COMMENT 'クーポンが適用されたライドのID',
  PRIMARY KEY (user_id, code)
)
  COMMENT 'クーポンテーブル';

ALTER TABLE coupons ADD INDEX code(code);
ALTER TABLE coupons ADD INDEX user_id_used_by_created_at(user_id, used_by, created_at);
ALTER TABLE coupons ADD INDEX used_by(used_by);
ALTER TABLE rides ADD INDEX user_id_created_at(user_id, created_at desc);
ALTER TABLE rides ADD INDEX chair_id_created_at(chair_id, created_at desc);
ALTER TABLE rides ADD INDEX chair_id_updated_at(chair_id, updated_at desc);
ALTER TABLE chairs ADD INDEX access_token(access_token);
ALTER TABLE chairs ADD INDEX owner_id(owner_id);
ALTER TABLE chairs ADD INDEX is_active_current_ride_id(is_active, current_ride_id);


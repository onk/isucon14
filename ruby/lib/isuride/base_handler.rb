# frozen_string_literal: true

Bundler.require

# mysql2-cs-bind gem にマイクロ秒のサポートを入れる
module Mysql2CsBindPatch
  def quote(rawvalue)
    if rawvalue.respond_to?(:strftime)
      "'#{rawvalue.strftime('%Y-%m-%d %H:%M:%S.%6N')}'"
    else
      super
    end
  end
end
Mysql2::Client.singleton_class.prepend(Mysql2CsBindPatch)

module Isuride
  class BaseHandler < Sinatra::Base
    INITIAL_FARE = 500
    FARE_PER_DISTANCE = 100

    # enable :logging
    set :show_exceptions, :after_handler

    class HttpError < Sinatra::Error
      attr_reader :code

      def initialize(code, message)
        super(message || "HTTP error #{code}")
        @code = code
      end
    end
    error HttpError do
      e = env['sinatra.error']
      status e.code
      json(message: e.message)
    end

    helpers Sinatra::Cookies

    helpers do
      def bind_json(data_class)
        body = JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
        data_class.new(**data_class.members.map { |key| [key, body[key]] }.to_h)
      end

      def db
        Thread.current[:db] ||= connect_db
      end

      def redis
        Thread.current[:redis] ||= connect_redis
      end

      def connect_db
        Mysql2::Client.new(
          host: ENV.fetch('ISUCON_DB_HOST', '127.0.0.1'),
          port: ENV.fetch('ISUCON_DB_PORT', '3306').to_i,
          username: ENV.fetch('ISUCON_DB_USER', 'isucon'),
          password: ENV.fetch('ISUCON_DB_PASSWORD', 'isucon'),
          database: ENV.fetch('ISUCON_DB_NAME', 'isuride'),
          symbolize_keys: true,
          cast_booleans: true,
          database_timezone: :utc,
          application_timezone: :utc,
        )
      end

      def connect_redis
        RedisClient.new(
          host: ENV.fetch('ISUCON_REDIS_HOST', '127.0.0.1'),
          port: 6379,
        )
      end

      def db_transaction(&block)
        db.query('BEGIN')
        ok = false
        begin
          retval = block.call(db)
          db.query('COMMIT')
          ok = true
          retval
        ensure
          unless ok
            db.query('ROLLBACK')
          end
        end
      end

      def db_without_transaction(&block)
        block.call(db)
      end

      def time_msec(time)
        time.to_i*1000 + time.usec/1000
      end

      # マンハッタン距離を求める
      def calculate_distance(a_latitude, a_longitude, b_latitude, b_longitude)
        (a_latitude - b_latitude).abs + (a_longitude - b_longitude).abs
      end

      def calculate_fare(pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        metered_fare = FARE_PER_DISTANCE * calculate_distance(pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        INITIAL_FARE + metered_fare
      end

      def match_chair_for_ride(ride, wait_time = 200)
        now_msec = time_msec(Time.now)
        chairs = db.query(<<~SQL).to_a
          SELECT *
          FROM chairs
          WHERE is_active = TRUE AND current_ride_id IS NULL
          AND total_distance_updated_at IS NOT NULL
          ORDER BY chairs.speed DESC
          LIMIT 100
        SQL

        ride_distance = calculate_distance(
          ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude),
          ride.fetch(:destination_latitude), ride.fetch(:destination_longitude)
        )

        # (待ち時間 + 実乗車時間)が最小になるように椅子を選ぶ
        #   (待ち距離 + 実乗車距離) / 速度
        sorted = chairs.sort_by { |chair|
          pickup_distance = calculate_distance(
            ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude),
            chair.fetch(:latitude), chair.fetch(:longitude)
          )

          [
            (pickup_distance + ride_distance).to_f / chair[:speed],
            pickup_distance, # 合計が同じなら近い椅子を優先する
          ]
        }

        sorted.each do |matched|
          pickup_distance = calculate_distance(
            ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude),
            matched.fetch(:latitude), matched.fetch(:longitude)
          )
          # 椅子が別の町だったらスキップして次の椅子を探す
          # distance が > 250 だったら別の町ということにする
          next if pickup_distance > 250

          # 50 以上かかる場合は近くの椅子が空くまでちょっと (200ms) 待ってみる
          # 200ms 以上待っても近くの椅子が空かない場合は諦めてアサインする
          if (pickup_distance + ride_distance).to_f / matched[:speed] > wait_time
            if now_msec - time_msec(ride.fetch(:created_at)) < 200
              next
            end
          end

          db.xquery('UPDATE rides SET chair_id = ? WHERE id = ?', matched.fetch(:id), ride.fetch(:id))
          db.xquery('UPDATE chairs SET current_ride_id = ? WHERE id = ?', ride.fetch(:id), matched.fetch(:id))
          break
        end
      end
    end
  end
end

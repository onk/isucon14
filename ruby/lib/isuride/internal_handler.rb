# frozen_string_literal: true

module Isuride
  class InternalHandler < BaseHandler
    # このAPIをインスタンス内から一定間隔で叩かせることで、椅子とライドをマッチングさせる
    # GET /api/internal/matching
    get '/matching' do
      # MEMO: 一旦最も待たせているリクエストに適当な空いている椅子マッチさせる実装とする。おそらくもっといい方法があるはず…
      rides = db.query('SELECT * FROM rides WHERE chair_id IS NULL ORDER BY created_at LIMIT 20').to_a

      rides.each do |ride|
        match_chair_for_ride(ride)
      end

      204
    end

    helpers do
      def match_chair_for_ride(ride)
        chairs = db.query(<<~SQL).to_a
          SELECT *
          FROM chairs
          WHERE is_active = TRUE AND current_ride_id IS NULL
          ORDER BY chairs.speed DESC
          LIMIT 100
        SQL

        # 速度が速い＆距離が近い順に椅子を探す
        sorted = chairs.sort_by { |chair|
          [
            -chair[:speed],
            calculate_distance(ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude), chair.fetch(:latitude), chair.fetch(:longitude))
          ]
        }

        sorted.each do |matched|
          # 椅子が別の町だったらスキップして次の椅子を探す
          # distanec が > 50 だったら別の町ということにする
          distance = calculate_distance(ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude), matched.fetch(:latitude), matched.fetch(:longitude))
          next if distance > 50

          db.xquery('UPDATE rides SET chair_id = ? WHERE id = ?', matched.fetch(:id), ride.fetch(:id))
          db.xquery('UPDATE chairs SET current_ride_id = ? WHERE id = ?', ride.fetch(:id), matched.fetch(:id))
          break
        end
      end
    end
  end
end

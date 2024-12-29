# frozen_string_literal: true

module Isuride
  class InternalHandler < BaseHandler
    # このAPIをインスタンス内から一定間隔で叩かせることで、椅子とライドをマッチングさせる
    # GET /api/internal/matching
    get '/matching' do
      # MEMO: 一旦最も待たせているリクエストに適当な空いている椅子マッチさせる実装とする。おそらくもっといい方法があるはず…
      rides = db.query('SELECT * FROM rides WHERE chair_id IS NULL ORDER BY created_at LIMIT 20').to_a

      # 20件取ってきた中で遠い順に処理する
      # (遠い ride に速い椅子を割り当てることで乗車時間を短くするため)
      rides.sort_by {|ride|
        -calculate_distance(
          ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude),
          ride.fetch(:destination_latitude), ride.fetch(:destination_longitude)
        )
      }.each do |ride|
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
          # 椅子が別の町だったらスキップして次の椅子を探す
          # distanec が > 250 だったら別の町ということにする
          distance = calculate_distance(ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude), matched.fetch(:latitude), matched.fetch(:longitude))
          next if distance > 250

          db.xquery('UPDATE rides SET chair_id = ? WHERE id = ?', matched.fetch(:id), ride.fetch(:id))
          db.xquery('UPDATE chairs SET current_ride_id = ? WHERE id = ?', ride.fetch(:id), matched.fetch(:id))
          break
        end
      end
    end
  end
end

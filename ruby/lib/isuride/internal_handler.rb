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
  end
end

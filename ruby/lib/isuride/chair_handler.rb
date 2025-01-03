# frozen_string_literal: true

module Isuride
  class ChairHandler < BaseHandler
    CurrentChair = Data.define(
      :id,
      :owner_id,
      :name,
      :model,
      :speed,
      :is_active,
      :access_token,
      :created_at,
      :updated_at,
      :latitude,
      :longitude,
      :total_distance,
      :total_distance_updated_at,
      :total_rides_count,
      :total_evaluation,
      :current_ride_id,
    )

    before do
      if request.path == '/api/chair/chairs'
        next
      end

      @access_token = cookies[:chair_session]
      if @access_token.nil?
        raise HttpError.new(401, 'chair_session cookie is required')
      end
    end

    ChairPostChairsRequest = Data.define(:name, :model, :chair_register_token)

    # POST /api/chair/chairs
    post '/chairs' do
      req = bind_json(ChairPostChairsRequest)
      if req.name.nil? || req.model.nil? || req.chair_register_token.nil?
        raise HttpError.new(400, 'some of required fields(name, model, chair_register_token) are empty')
      end

      owner = db.xquery('SELECT * FROM owners WHERE chair_register_token = ?', req.chair_register_token).first
      if owner.nil?
        raise HttpError.new(401, 'invalid chair_register_token')
      end

      chair_id = ULID.generate
      access_token = SecureRandom.hex(32)

      speed = db.xquery('SELECT speed FROM chair_models WHERE name = ?', req.model).first[:speed]

      db.xquery('INSERT INTO chairs (id, owner_id, name, model, speed, is_active, access_token) VALUES (?, ?, ?, ?, ?, ?, ?)', chair_id, owner.fetch(:id), req.name, req.model, speed, false, access_token)

      cookies.set(:chair_session, httponly: false, value: access_token, path: '/')
      cookies.set(:chair_id, httponly: false, value: chair_id, path: '/')
      status(201)
      json(id: chair_id, owner_id: owner.fetch(:id))
    end

    PostChairActivityRequest = Data.define(:is_active)

    # POST /api/chair/activity
    post '/activity' do
      req = bind_json(PostChairActivityRequest)

      db.xquery('UPDATE chairs SET is_active = ? WHERE id = ?', req.is_active, current_chair_id)

      status(204)
    end

    PostChairCoordinateRequest = Data.define(:latitude, :longitude)

    # POST /api/chair/coordinate
    post '/coordinate' do
      req = bind_json(PostChairCoordinateRequest)

      response = db_without_transaction do |tx|
        now = Time.now
        set_current_chair
        # update latest lat/lon, total_distance
        distance = if @current_chair.latitude
                     calculate_distance(@current_chair.latitude, @current_chair.longitude, req.latitude, req.longitude)
                   else
                     0
                   end
        tx.xquery('UPDATE chairs SET latitude = ?, longitude = ?, total_distance = total_distance + ?, total_distance_updated_at = ? WHERE id = ?', req.latitude, req.longitude, distance, now, @current_chair.id)

        if @current_chair.current_ride_id
          ride = tx.xquery('SELECT * FROM rides WHERE id = ?', @current_chair.current_ride_id).first
          status = ride.fetch(:status)
          if status != 'COMPLETED'
            if req.latitude == ride.fetch(:pickup_latitude) && req.longitude == ride.fetch(:pickup_longitude) && status == 'ENROUTE'
              tx.xquery('UPDATE rides SET status = ? WHERE id = ?', 'PICKUP', ride.fetch(:id))
              redis.call('RPUSH', "#{ride.fetch(:id)}:app", "PICKUP")
              redis.call('RPUSH', "#{ride.fetch(:id)}:chair", "PICKUP")
            end

            if req.latitude == ride.fetch(:destination_latitude) && req.longitude == ride.fetch(:destination_longitude) && status == 'CARRYING'
              tx.xquery('UPDATE rides SET status = ? WHERE id = ?', 'ARRIVED', ride.fetch(:id))
              redis.call('RPUSH', "#{ride.fetch(:id)}:app", "ARRIVED")
              redis.call('RPUSH', "#{ride.fetch(:id)}:chair", "ARRIVED")
            end
          end
        end

        { recorded_at: time_msec(now) }
      end

      json(response)
    end

    # GET /api/chair/notification
    get '/notification' do
      response = db_without_transaction do |tx|
        set_current_chair
        unless @current_chair.current_ride_id
          halt json(data: nil, retry_after_ms: 500)
        end

        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', @current_chair.current_ride_id).first

        yet_sent_ride_status = redis.call('LPOP', "#{ride.fetch(:id)}:chair")
        status =
          if yet_sent_ride_status.nil?
            ride.fetch(:status)
          else
            yet_sent_ride_status
          end

        user = tx.xquery('SELECT * FROM users WHERE id = ?', ride.fetch(:user_id)).first

        unless yet_sent_ride_status.nil?
          if status == 'COMPLETED'
            tx.xquery('UPDATE chairs SET current_ride_id = NULL WHERE id = ?', ride.fetch(:chair_id))
          end
        end

        retry_after_ms = case status
                         when 'ENROUTE'
                           distance = calculate_distance(@current_chair.latitude, @current_chair.longitude, ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude))
                           [(distance / @current_chair.speed) * 1000 , 100].max
                         when 'CARRYING'
                           distance = calculate_distance(@current_chair.latitude, @current_chair.longitude, ride.fetch(:destination_latitude), ride.fetch(:destination_longitude))
                           [(distance / @current_chair.speed) * 1000 , 100].max
                         else # when 'MATCHING', 'PICKUP', 'ARRIVED', 'COMPLETED'
                           500
                         end

        {
          data: {
            ride_id: ride.fetch(:id),
            user: {
              id: user.fetch(:id),
              name: "#{user.fetch(:firstname)} #{user.fetch(:lastname)}",
            },
            pickup_coordinate: {
              latitude: ride.fetch(:pickup_latitude),
              longitude: ride.fetch(:pickup_longitude),
            },
            destination_coordinate: {
              latitude: ride.fetch(:destination_latitude),
              longitude: ride.fetch(:destination_longitude),
            },
            status:,
          },
          retry_after_ms: retry_after_ms,
        }
      end

      json(response)
    end

    PostChairRidesRideIDStatusRequest = Data.define(:status)

    # POST /api/chair/rides/:ride_id/status
    post '/rides/:ride_id/status' do
      ride_id = params[:ride_id]
      req = bind_json(PostChairRidesRideIDStatusRequest)

      db_without_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.fetch(:chair_id) != current_chair_id
          raise HttpError.new(400, 'not assigned to this ride')
        end

        case req.status
        # Acknowledge the ride
        when 'ENROUTE'
          tx.xquery('UPDATE rides SET status = ? WHERE id = ?', 'ENROUTE', ride.fetch(:id))
          redis.call('RPUSH', "#{ride.fetch(:id)}:app", "ENROUTE")
          redis.call('RPUSH', "#{ride.fetch(:id)}:chair", "ENROUTE")
        # After Picking up user
        when 'CARRYING'
          status = ride.fetch(:status)
          if status != 'PICKUP'
            raise HttpError.new(400, 'chair has not arrived yet')
          end
          tx.xquery('UPDATE rides SET status = ? WHERE id = ?', 'CARRYING', ride.fetch(:id))
          redis.call('RPUSH', "#{ride.fetch(:id)}:app", "CARRYING")
          redis.call('RPUSH', "#{ride.fetch(:id)}:chair", "CARRYING")
        else
          raise HttpError.new(400, 'invalid status')
        end
      end

      status(204)
    end

    helpers do
      def set_current_chair
        chair = db.xquery('SELECT * FROM chairs WHERE access_token = ?', @access_token).first
        @current_chair = CurrentChair.new(**chair)
      end

      def current_chair_id
        cookies[:chair_id]
      end
    end
  end
end

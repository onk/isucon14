# frozen_string_literal: true

require 'ulid'

require 'isuride/base_handler'

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
      set_current_chair

      response = db_transaction do |tx|
        chair_location_id = ULID.generate
        # update latest lat/lon, total_distance
        total_distance = if @current_chair.latitude == 999999
                           0
                         else
                           @current_chair.total_distance +
                             calculate_distance(@current_chair.latitude, @current_chair.longitude, req.latitude, req.longitude)
                         end
        tx.xquery('UPDATE chairs SET latitude = ?, longitude = ?, total_distance = ?, total_distance_updated_at = now(), updated_at = updated_at WHERE id = ?', req.latitude, req.longitude, total_distance, @current_chair.id)

        if @current_chair.current_ride_id
          ride = tx.xquery('SELECT * FROM rides WHERE id = ?', @current_chair.current_ride_id).first
          status = ride.fetch(:status)
          if status != 'COMPLETED' && status != 'CANCELED'
            if req.latitude == ride.fetch(:pickup_latitude) && req.longitude == ride.fetch(:pickup_longitude) && status == 'ENROUTE'
              tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride.fetch(:id), 'PICKUP')
              tx.xquery('UPDATE rides SET status = ?, updated_at = ? WHERE id = ?', 'PICKUP', ride.fetch(:updated_at), ride.fetch(:id))
            end

            if req.latitude == ride.fetch(:destination_latitude) && req.longitude == ride.fetch(:destination_longitude) && status == 'CARRYING'
              tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride.fetch(:id), 'ARRIVED')
              tx.xquery('UPDATE rides SET status = ?, updated_at = ? WHERE id = ?', 'ARRIVED', ride.fetch(:updated_at), ride.fetch(:id))
            end
          end
        end

        { recorded_at: time_msec(Time.now) }
      end

      json(response)
    end

    # GET /api/chair/notification
    get '/notification' do
      response = db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE chair_id = ? ORDER BY updated_at DESC LIMIT 1', current_chair_id).first
        unless ride
          halt json(data: nil, retry_after_ms: 300)
        end

        yet_sent_ride_status = tx.xquery('SELECT * FROM ride_statuses WHERE ride_id = ? AND chair_sent_at IS NULL ORDER BY created_at ASC LIMIT 1', ride.fetch(:id)).first
        status =
          if yet_sent_ride_status.nil?
            ride.fetch(:status)
          else
            yet_sent_ride_status.fetch(:status)
          end

        user = tx.xquery('SELECT * FROM users WHERE id = ? FOR SHARE', ride.fetch(:user_id)).first

        unless yet_sent_ride_status.nil?
          tx.xquery('UPDATE ride_statuses SET chair_sent_at = CURRENT_TIMESTAMP(6) WHERE id = ?', yet_sent_ride_status.fetch(:id))
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
          retry_after_ms: 300,
        }
      end

      json(response)
    end

    PostChairRidesRideIDStatusRequest = Data.define(:status)

    # POST /api/chair/rides/:ride_id/status
    post '/rides/:ride_id/status' do
      ride_id = params[:ride_id]
      req = bind_json(PostChairRidesRideIDStatusRequest)

      db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.fetch(:chair_id) != current_chair_id
          raise HttpError.new(400, 'not assigned to this ride')
        end

        case req.status
        # Acknowledge the ride
        when 'ENROUTE'
          tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride.fetch(:id), 'ENROUTE')
          tx.xquery('UPDATE rides SET status = ?, updated_at = ? WHERE id = ?', 'ENROUTE', ride.fetch(:updated_at), ride.fetch(:id))
        # After Picking up user
        when 'CARRYING'
          status = ride.fetch(:status)
          if status != 'PICKUP'
            raise HttpError.new(400, 'chair has not arrived yet')
          end
          tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride.fetch(:id), 'CARRYING')
          tx.xquery('UPDATE rides SET status = ?, updated_at = ? WHERE id = ?', 'CARRYING', ride.fetch(:updated_at), ride.fetch(:id))
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

#encoding: utf-8

require './spec/spec_helper'
require './spec/integration/shared_context'

describe 'Integration' do
  include_context "shared stuff"
  before(:each) { fork_slanger }

  describe 'regular channels:' do
    it 'pushes messages to interested websocket connections' do
      messages = messages_for(
        ->(ws, m) { m.length < 3},
        ->(ws, m) { Pusher['MY_CHANNEL'].trigger_async 'an_event', { some: "Mit Raben Und Wölfen" } }
      ) do |ws, m|
        ws.callback do
          ws.send({ event: 'pusher:subscribe', data: { channel: 'MY_CHANNEL'} }.to_json)
        end if m.one?
      end

      messages.should have_attributes connection_established: true, id_present: true,
        last_event: 'an_event', last_data: { some: "Mit Raben Und Wölfen" }.to_json
    end

    it 'avoids duplicate events' do
      client2_messages  = []

      client1_messages = em_stream do |client1, client1_messages|
        # if this is the first message to client 1 set up another connection from the same client
        if client1_messages.one?
          client1.callback do
            client1.send({ event: 'pusher:subscribe', data: { channel: 'MY_CHANNEL'} }.to_json)
          end

          client2_messages = messages_for(
            ->(ws,m) { m.length < 3 },
            ->(ws,m) {
              socket_id = client1_messages.first['data']['socket_id']
              Pusher['MY_CHANNEL'].trigger_async 'an_event', { some: 'data' }, socket_id
            }
          ) do |client2, client2_messages|
            client2.callback do
              client2.send({ event: 'pusher:subscribe', data: { channel: 'MY_CHANNEL'} }.to_json)
            end if client2_messages.one?
          end

        end
      end

      client1_messages.should have_attributes count: 2

      client2_messages.should have_attributes last_event: 'an_event',
        last_data: { some: 'data' }.to_json
    end
  end

  describe 'private channels' do
    context 'with valid authentication credentials:' do
      it 'accepts the subscription request' do
        messages = messages_for(
          ->(ws, m) { m.length < 2},
          ->(ws, m) { private_channel ws, m.first})

          messages.should have_attributes connection_established: true,
            count: 2,
            id_present: true,
            last_event: 'pusher_internal:subscription_succeeded'
      end
    end

    context 'with bogus authentication credentials:' do
      it 'sends back an error message' do
        messages  = messages_for(
          ->(ws, m){ m.length < 2 },
          ->(ws, m){ ws.send({ event: 'pusher:subscribe',
                              data: { channel: 'private-channel',
                                      auth: 'bogus' } }.to_json)}
        )

        messages.should have_attributes connection_established: true, count: 2, id_present: true, last_event:
          'pusher:error'
        messages.last['data']['message'].should =~(/^Invalid signature: Expected HMAC SHA256 hex digest of/)
      end
    end

    describe 'client events' do
      it "sends event to other channel subscribers" do
        client1_messages, client2_messages  = [], []

        em_thread do
          client1, client2 = new_websocket, new_websocket
          client2_messages, client1_messages = [], []

          client1.callback {}

          stream(client1, client1_messages) do |message|
            if client1_messages.length < 2
              private_channel client1, client1_messages.first
            elsif client1_messages.length == 3
              EM.stop
            end
          end

          client2.callback {}

          stream(client2, client2_messages) do |message|
            if client2_messages.length < 2
              private_channel client2, client2_messages.first
            else
              client2.send({ event: 'client-something', data: { some: 'stuff' }, channel: 'private-channel' }.to_json)
            end
          end
        end

        client1_messages.none? { |m| m['event'] == 'client-something' }
        client2_messages.one?  { |m| m['event'] == 'client-something' }
      end
    end
  end

  describe 'presence channels:' do
    context 'subscribing without channel data' do
      context 'and bogus authentication credentials' do
        it 'sends back an error message' do
          messages = messages_for(
            ->(ws, m) { m.length < 2},
            ->(ws, m) { ws.send({ event: 'pusher:subscribe', data: { channel: 'presence-channel', auth: 'bogus' } }.to_json) })

          messages.should have_attributes(
            connection_established: true,
            id_present: true,
            count: 2,
            last_event: 'pusher:error')

          messages.last['data']['message'].=~(/^Invalid signature: Expected HMAC SHA256 hex digest of/).should be_true
        end
      end
    end

    context 'subscribing with channel data' do
      context 'and bogus authentication credentials' do
        it 'sends back an error message' do
          messages = messages_for(
            ->(ws, m) { m.length < 2},
            ->(ws, m) { send_subscribe( user: ws,
                             user_id: user_id,
                             name: 'SG',
                             message: {data: {socket_id: 'bogus'}}.with_indifferent_access) })


          messages.should have_attributes first_event: 'pusher:connection_established', count: 2,
            id_present: true

          # Channel id should be in the payload
          messages.last['event'].should == 'pusher:error'
          messages.last['data']['message'].=~(/^Invalid signature: Expected HMAC SHA256 hex digest of/).should be_true
        end
      end

      context 'with genuine authentication credentials'  do
        it 'sends back a success message' do
          messages = messages_for(
            ->(ws, m) { m.length < 2},
            ->(ws, m) { send_subscribe( user: ws,
                                        user_id: user_id,
                                        name: 'SG',
                                        message: m.first)})

          messages.should have_attributes connection_established: true, count: 2

          messages.last.should == {"channel"=>"presence-channel",
                                   "event"=>"pusher_internal:subscription_succeeded",
                                   "data"=>{"presence"=>
                                            {"count"=>1,
                                             "ids"=>[user_id],
                                             "hash"=>
                                            {user_id =>{"name"=>"SG"}}}}}
        end




        context 'with more than one subscriber subscribed to the channel' do
          it 'sends a member added message to the existing subscribers' do
            messages  = em_stream do |user1, messages|
              case messages.length
              when 1
                send_subscribe(user: user1,
                               user_id: user_id,
                               name: 'SG',
                               message: messages.first
                              )

              when 2
                new_websocket.tap do |u|
                  u.stream do |message|
                    send_subscribe({user: u,
                                    user_id: second_user_id,
                                    name: 'CHROME',
                                    message: JSON.parse(message)})
                  end
                end
              else
                EM.stop
              end

            end

            messages.should have_attributes connection_established: true, count: 3
            # Channel id should be in the payload
            messages[1].  should == {"channel"=>"presence-channel", "event"=>"pusher_internal:subscription_succeeded",
                                     "data"=>{"presence"=>{"count"=>1, "ids"=>[user_id], "hash"=>{user_id=>{"name"=>"SG"}}}}}

            messages.last.should == {"channel"=>"presence-channel", "event"=>"pusher_internal:member_added",
                                     "data"=>{"user_id"=>second_user_id, "user_info"=>{"name"=>"CHROME"}}}
          end

          it 'does not send multiple member added and member removed messages if one subscriber opens multiple connections, i.e. multiple browser tabs.' do
            messages  = em_stream do |user1, messages|
              case messages.length
              when 1
                send_subscribe(user: user1,
                               user_id: user_id,
                               name: 'SG',
                               message: messages.first)

              when 2
                10.times do
                  new_websocket.tap do |u|
                    u.stream do |message|
                      # remove stream callback
                      ## close the connection in the next tick as soon as subscription is acknowledged
                      u.stream { EM.next_tick { u.close_connection } }

                      send_subscribe({ user: u,
                                       user_id: second_user_id,
                                       name: 'CHROME',
                                       message: JSON.parse(message)})
                    end
                  end
                end
              when 4
                EM.next_tick { EM.stop }
              end

            end

            # There should only be one set of presence messages sent to the refernce user for the second user.
            messages.one? { |message| message['event'] == 'pusher_internal:member_added'   && message['data']['user_id'] == second_user_id }.should be_true
            messages.one? { |message| message['event'] == 'pusher_internal:member_removed' && message['data']['user_id'] == second_user_id }.should be_true

          end
        end
      end
    end
  end

  context "given invalid JSON as input" do

    it 'should not crash' do
      messages = messages_for ->(ws, m) { m.one? },
        ->(websocket, messages){
          websocket.callback do
            websocket.send("{ event: 'pusher:subscribe', data: { channel: 'MY_CHANNEL'} }23123")
            EM.next_tick { EM.stop }
          end
      }

      EM.run { new_websocket.tap { |u| u.stream { EM.next_tick { EM.stop } } }}
    end

  end
end

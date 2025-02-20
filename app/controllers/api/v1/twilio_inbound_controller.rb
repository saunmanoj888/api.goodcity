require "twilio-ruby"
require "goodcity/redis"

module Api
  module V1
    class TwilioInboundController < Api::V1::ApiController
      include TwilioConfig
      include ValidateTwilioRequest

      skip_authorization_check
      skip_before_action :validate_token, except: :accept_call
      skip_before_action :verify_authenticity_token, except: :accept_call, raise: false

      before_action :validate_twilio_request, except: :accept_call

      after_action :set_header, except: [:assignment, :hold_music]
      after_action :set_json_header, only: :assignment

      resource_description do
        short "Handle Twilio Inbound Voice Calls"
        description <<-EOS
          - Call from Donor is notified to Goodcity Staff who is subscribed
            to the Donor's recent Offer's private message thread.
          - Twilio will redirect it to the person who accepts the call.
            (Implemented using Twilio's Taskrouter feature.)
          - In case of any call-fallback, it will send airbreak notice.
        EOS
        formats ['application/json', 'text/xml']
        error 404, "Not Found"
        error 500, "Internal Server Error"
      end

      def_param_group :twilio_params do
        param :CallSid, String, desc: "SID of call"
        param :AccountSid, String, desc: "Twilio Account SID"
        param :ApiVersion, String, desc: "Twilio API version"
        param :Direction, String, desc: "inbound or outbound"
        param :To, String, desc: "phone number dialed by User(Donor)"
        param :Called, String, desc: "phone number dialed by User(Donor)"
        param :Caller, String, desc: "Phone number of Caller(Donor)"
        param :From, String, desc: "Phone number of Caller(Donor)"
      end

      api :POST, "/v1/twilio_inbound/assignment", "Called by Twilio when worker becomes Idle and Task is added to TaskQueue"
      param :AccountSid, String, desc: "Twilio Account SID"
      param :WorkspaceSid, String, desc: "Twilio Workspace SID"
      param :WorkflowSid, String, desc: "Twilio Workflow SID"
      param :ReservationSid, String, desc: "Twilio Task Reservation SID"
      param :TaskQueueSid, String, desc: "Twilio Task Queue SID"
      param :TaskSid, String, desc: "Twilio current Task SID"
      param :WorkerSid, String, desc: "Twilio worker SID"
      param :TaskAge, String
      param :TaskPriority, String
      param :TaskAttributes, String, desc: <<-EOS
        Serialized hash of following Task Attributes
        - param :caller, String, desc: 'Phone number of Caller(Donor)'
        - param :To, String, desc: 'phone number dialed by User(Donor)'
        - param :Called, String, desc: 'phone number dialed by User(Donor)'
        - param :direction, String, desc: 'inbound or outbound'
        - param :from, String, desc: 'Phone number of Caller(Donor)'
        - param :api_version, String, desc: 'Twilio API version'
        - param :call_sid, String, desc: 'SID of call'
        - param :user_id, Integer, desc: 'id of user(donor)'
        - param :selected_language, String, desc: 'ex: 'en''
        - param :call_status, String, desc: 'Status of call ex: ringing'
        - param :account_sid, String, desc: 'Twilio Account SID'
      EOS
      param :WorkerAttributes, String, desc: <<-EOS
        Serialized hash of following Worker Attributes
        - param :languages, Array, desc: "ex: [\"en\"]"
        - param :user_id, String, desc: "Id of User"
      EOS
      def assignment
        donor_id = JSON.parse(params["TaskAttributes"])["user_id"]
        mobile   = TwilioInboundCallManager.new(user_id: donor_id).mobile

        if mobile
          assignment_instruction = {
            instruction: 'dequeue',
            post_work_activity_sid: activity_sid("Offline"),
            from: voice_number,
            to: mobile
          }
        else
          assignment_instruction = {}
        end
        render json: assignment_instruction.to_json
      end

      api :POST, '/v1/twilio_inbound/call_complete', "This action will be called from twilio when call is completed"
      description <<-EOS
        - Delete details related to current call from Redis
        - Update twilio-worker state from 'Idle' to 'Offline'
      EOS
      param_group :twilio_params
      param :CallStatus, String, desc: "Status of call ex: completed"
      param :Timestamp, String, desc: "Timestamp when call is completed"
      param :CallDuration, String, desc: "Time Duration of Call in seconds"
      def call_complete
        TwilioInboundCallManager.new(user_id: user.id).call_teardown if user
        mark_worker_offline
        render json: {}
      end

      api :POST, '/v1/twilio_inbound/call_fallback', "On runtime exception, invalid response or timeout at api request from Twilio to our application(at 'api/v1/twilio_inbound/voice')"
      param_group :twilio_params
      param :ErrorUrl, String, desc: "Url at which error is occured ex: 'http://api-staging.goodcity.hk/api/v1/twilio_inbound/voice'"
      param :CallStatus, String, desc: "Status of call ex: ringing"
      param :ErrorCode, String, desc: "Code of error, ex: 11200"
      def call_fallback
        Rollbar.error(Exception, parameters: params,
          error_class: "TwilioError", error_message: "Twilio Voice Call Error")
        response = Twilio::TwiML::VoiceResponse.new do |r|
          r.say(message: "Unfortunately there is some issue with connecting to Goodcity. Please try again after some time. Thank you.")
          r.hangup
        end
        render_twiml response
      end

      api :POST, "/v1/twilio_inbound/voice", "Called by Twilio when Donor calls to Goodcity Voice Number."
      param_group :twilio_params
      param :CallStatus, String, desc: "Status of call ex: ringing"
      def voice
        call_manager = TwilioInboundCallManager.new(mobile: params["From"])
        if call_manager.caller_is_admin?
          response = admin_call_response
        else
          active_caller = call_manager.caller_has_active_offer?
          response = Twilio::TwiML::VoiceResponse.new do |r|
            unless active_caller
              r.dial do |d|
                d.number(GOODCITY_NUMBER)
              end
            else
              enqueue_donor_call(r)
              ask_callback(r)
              accept_voicemail(r)
            end
          end
        end
        render_twiml response
      end

      api :POST, "/v1/twilio_inbound/hold_donor", "Twilio Response to the caller waiting in queue"
      param_group :twilio_params
      param :QueueSid, String, desc: "Twilio API version"
      param :CallStatus, String, desc: "Status of call ex: ringing"
      param :QueueTime, String, desc: "Time spent by current caller in queue"
      param :AvgQueueTime, String
      param :QueuePosition, String
      param :CurrentQueueSize, String
      def hold_donor
        TwilioInboundCallManager.new(user_id: user.id).notify_incoming_call if offline_worker

        if(params['QueueTime'].to_i < TWILIO_QUEUE_WAIT_TIME)
          response = Twilio::TwiML::VoiceResponse.new do |r|
            r.say(message: "Hello #{user.full_name},") if user
            r.say(message: I18n.t('twilio.thank_you_calling_message'))
            r.play(url: api_v1_twilio_inbound_hold_music_url)
          end
        else
          response = Twilio::TwiML::VoiceResponse.new { |r| r.leave }
        end
        render_twiml response
      end

      api :POST, "/v1/accept_callback", "Twilio response sent when user press 1 key"
      param_group :twilio_params
      param :CallStatus, String, desc: "Status of call ex: in-progress"
      param :Digits, String, desc: "Digits entered by Caller"
      param :msg, String
      def accept_callback
        if params["Digits"] == "1"
          TwilioInboundCallManager.new(mobile: params["From"]).send_donor_call_response
          response = Twilio::TwiML::VoiceResponse.new do |r|
            r.say(message:"Thank you, our staff will call you as soon as possible. Goodbye.")
            r.hangup
          end
        end
        render_twiml response
      end

      api :POST, '/v1/send_voicemail', "After voicemail, recording-Link sent to message thread and call is disconnected."
      param_group :twilio_params
      param :CallStatus, String, desc: "Status of call ex: completed"
      param :RecordingUrl, String, desc: "Url of recording ex: http://api.twilio.com/2010-04-0Accounts/account_sid/Recordings/recording_sid"
      param :Digits, String
      param :RecordingDuration, String, desc: "Recording Duration in seconds"
      param :RecordingSid, String, desc: "SID of recording"
      def send_voicemail
        TwilioInboundCallManager.new(user_id: user.try(:id), record_link: params["RecordingUrl"]).send_donor_call_response
        response = Twilio::TwiML::VoiceResponse.new do |r|
          r.say(message:"Goodbye.")
          r.hangup
        end
        render_twiml response
      end

      api :GET, '/v1/twilio_inbound/accept_call'
      description <<-EOS
        - Set redis value: { "twilio_donor_<donor_id>" => <mobile> }
        - Update twilio-worker state from 'Offline' to 'Idle'
        - Send Call notification to Admin Staff.
      EOS
      def accept_call
        donor_id = params['donor_id']
        call_manager = TwilioInboundCallManager.new(user_id: donor_id, mobile: current_user.mobile)

        unless call_manager.mobile
          call_manager.set_mobile
          offline_worker.update(activity_sid: activity_sid('Idle'))
          call_manager.notify_accepted_call
        end
        render json: {}
      end

      api :GET, '/v1/twilio_inbound/hold_music', "Returns mp3 file played for user while waiting in queue."
      def hold_music
        response.headers["Content-Type"] = "audio/mpeg"
        send_file "app/assets/audio/30_sec_hold_music.mp3", type: "audio/mpeg"
      end

      api :POST, "/v1/accept_offer_id", "Twilio response sent when input offer ID"
      param_group :twilio_params
      param :CallStatus, String, desc: "Status of call ex: in-progress"
      param :Digits, String, desc: "Digits entered by Caller"
      def accept_offer_id
        response = Twilio::TwiML::VoiceResponse.new do |r|
          if params["Digits"]
            twilio_manager = TwilioInboundCallManager.new(offer_id: params["Digits"], mobile: params["From"])
            donor = twilio_manager.offer_donor

            if donor
              r.say(message:"Connecting to #{donor.full_name}..")
              r.dial(callerId: voice_number) do |d|
                d.number donor.mobile
              end
              twilio_manager.log_outgoing_call
            else
              r.Say "You have entered invalid offer ID. Please try again."
              ask_offer_id(r)
            end
          else
            hangup_call(r)
          end
        end
        render_twiml response
      end

      private

      def admin_call_response
        Twilio::TwiML::VoiceResponse.new do |r|
          r.say(message:"Hello #{user.full_name},") if user
          ask_offer_id(r, true)
          hangup_call(r)
        end
      end

      def ask_offer_id(r, play_welcome=false)
        # ask Donor to leave message on voicemail
        r.gather numDigits: "5",  action: api_v1_twilio_inbound_accept_offer_id_path do |g|
          g.say(message: I18n.t('twilio.input_offer_id_message')) if play_welcome
        end
      end

      def ask_callback(r)
        # ask Donor to leave message on voicemail
        r.gather numDigits: "1", timeout: 3,  action: api_v1_twilio_inbound_accept_callback_path do |g|
          g.say(message: "Unfortunately none of our staff are able to take your call at the moment." )
          g.say(message: "You can request a call-back without leaving a message by pressing 1." )
          g.say(message: "Otherwise, leave a message after the tone and our staff will get back to you as soon as possible. Thank you.")
        end
      end

      def accept_voicemail(r)
        r.record maxLength: "60", playBeep: true, action: api_v1_twilio_inbound_send_voicemail_path
      end

      def enqueue_donor_call(r)
        task = { "selected_language" => "en", "user_id" => user.id }.to_json
        r.enqueue(workflow_sid: twilio_creds[:workflow_sid], wait_url: api_v1_twilio_inbound_hold_donor_path, wait_url_method: "post") do |t|
          t.task task
        end
      end

      def hangup_call(r)
        r.say(message:"Goodbye")
        r.hangup
      end
    end
  end
end

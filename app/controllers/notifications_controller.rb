
class NotificationsController < ApplicationController
  include Webhookable
  skip_before_action :verify_authenticity_token

  def index
  end


  def desktop_send
    # establish Twilio REST Client with proper credentials
    client = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN']

        from = ENV['TEXTIGO_PHONE']
        select_friends = Group.find(params[:id]).friends
        # send SMS from Twilio phone number to each friend in group
        select_friends.each do |friend|
          client.account.messages.create(
            :from => from,
            :to => friend.phone,
            :body => "Hey #{friend.name}, Hackattack at 6PM. Bring Computer!" # add form logic for this text body
          )
    end
    # Need to add Event.create here (also need to add a form field for event create)
    # Event.create(name: @message_body, host: @user.id, guests: {}, status: 'active')

    redirect_to root_url
  end


  def incoming
    # collect phone number and message from SMS
    @phone_number = params[:From]
    @body = params[:Body].downcase
    # split SMS into array of words
    message_array = @body.split

    # if you are sending an SMS in response to a blast text, you are probably a friend in a group
    if Friend.exists?(phone: @phone_number)
      # get all friend IDs corresponding to phone number from all groups
      friend_ids = Friend.get_all_ids_from_number(@phone_number)
      # find first matching friend id of last invitation that matches phone number
      @active_invite = Invitation.find_matching_invitation(friend_ids).first.last
      # assign instance variables for use in other methods
      @friend_id = @active_invite.friend_id
      @event_id = @active_invite.event_id

      # if invite is active, manage reply logic
      if @active_invite
          session['person_type'] = 'guest'
          output = process_guest(@body, @phone_number, @active_invite)
      end

    # if you are sending a blast text, you are probably a user
    elsif User.exists?(phone: @phone_number)
      @user = User.find_by(phone: @phone_number)
      # first word of SMS should be the name of the group to which you are sending the message
      @group = @user.groups.find_by(name: message_array[0])
      if @group
        session['person_type'] = 'host'
        @message_body = message_array[1..-1].join(' ')
        # send the rest of the message (without the first word) to all friends in group
        @select_friends = @group.friends

        output = "Message sent to '#{message_array[0]}' group."
        event = Event.create(name: @message_body, host: @user.id, status: 'active')
        # create active event and invitations for each friend
        @select_friends.each { |friend| Invitation.create(friend_id: friend.id, event_id: event.id)}

        # see send_group method below
        send_group(@message_body, @select_friends, @user.name)
      else
        output = "#{message_array[0]} is not a group. please make one"
      end

    else
      output = "Hmm... Try creating a new event @ Textigo.com. No active invites or groups associated with this number."
    end

    # automated reply; lets user know whether their action succeeded or failed
    respond(output)
    # increment session counter so that we can keep track of replies (counts messages in both directions)
    session["counter"] += 1

  end

  # automated response to either party based on actions
  def respond(message)
    response = Twilio::TwiML::Response.new do |r|
      r.Message message
    end
    render text: response.text
  end

  # send blast text to group
  def send_group(msg, select_friends, host_name)
    @client = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN']

    from = ENV['TEXTIGO_PHONE']
        select_friends.each do |friend|
        @client.account.messages.create(
                    :from => from,
                    :to => friend.phone,
                    :body => "From #{host_name}:\nHey #{friend.name}, #{msg}, [In] or [Out]?"
                    )
        end
  end

  private

  # process guests' replies
    def process_guest(message, phone, active_invite)

      # define valid responses (positive and negative)
      in_array = ['in', 'i', 'y', 'yes']
      out_array = ['out', 'o', 'n', 'no']

      # split message into array of words
      message_array = @body.split

      # get responder's name
      name = get_name(phone)

      # if positive response
      if in_array.include?(message_array[0])
        # persist reply as 'yes'
         active_invite.reply = 'yes'
         active_invite.save
          output = "Glad you can make it, #{name}. See you there."
          active_event = Event.find(@event_id)
          # increment tally of total 'yes' replies
          active_event.increment_yes_total
          # keep host up to date on recipients' replies
          host_message = "New Yes RSVP from #{name}. Yes: #{active_event.yes_total} No: #{active_event.no_total}"
          # see send_host method below
          send_host(host_message, active_event.host)

          # if event is closed, send summary of people attending
          if active_event.close_event?
            names = active_event.attendee_names

            host_message = "Invitation filled. Total attending: #{active_event.total_invited}. Attendees: #{names.join(', ')}"
            send_host(host_message, active_event.host)
          end

        # if negative response
        elsif out_array.include?(message_array[0])
          current_invite = Invitation.find_by(friend_id: friend_id, event_id: event_id)
          # persist reply as 'no'
          current_invite.reply = 'no'
          current_invite.save
          output = "Sorry to miss you #{name}. Maybe next time."
          active_event = Event.find(@event_id)
          # increment tally of total 'no' replies
          active_event.increment_no_total
          # keep host up to date on recipients' replies
          host_message = "New No RSVP from #{name}. Yes: #{active_event.yes_total} No: #{active_event.no_total}"
          # see send_host method below
          send_host(host_message, active_event.host)

        else
          output =  "Sorry, I didn't understand your response, please just type [In] or [Out]. Thanks! (end of proc_guest)"
        end
      # return notification from Twilio based on reply
      return output
    end

    def get_name(phone_number)
      friend = Friend.find_by(phone: phone_number)
      friend.name
    end

    # handle sending messages to event host
    def send_host(output, host_id)

      host = User.find(host_id)

        @twilio_number = ENV['TEXTIGO_PHONE']
        @client = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN']
        message = @client.account.messages.create(
          :from => @twilio_number,
          :to => host.phone,
          :body => output,
        )

    end

end

# -*- coding: utf-8 -*-
class ConektaController < ApplicationController
  include Projects::BackersHelper
  before_action :load_current_rate, only: [:payment]

  def payment

    # backer creation begins here
    @backer = Backer.new(user: current_user, project: project, country: @visitor_country.alpha2)
    @backer.value = ((params[:backing_amount].to_f * Rails.cache.read(@backer.project.currency.downcase).to_f) / @current_rate).round(2)
    # first rescue block to move out
    begin
      reward = Reward.find(params[:reward_id])
      if @backer.value >= reward.minimum_value
        @backer.reward = reward
      end
    rescue ActiveRecord::RecordNotFound
      @backer.reward = nil
    end
    @backer.currency_value = params[:backing_amount]
    @backer.currency_code = @current_currency.iso_code
    @backer.payment_method = "Conekta"
    @backer.payment_token = params[:conektaTokenId]
    @backer.save
    verify_recaptcha(model: @backer, message: "Failed recaptcha.") if params["g-recaptcha-response"]
    # backer creation ends here

    @result = Hash.new

    # cant see the else or end of this conditional, aim to make each condition a single method
    unless @backer.errors.any?
      # second rescue bloc to move out
      begin
        customer = create_customer(params[:conektaTokenId])
        # too much nesting ins this hash
        attributes = {
          currency: Rails.application.secrets.currency_code,
          customer_info: {
            customer_id: customer.id
          },
          line_items: [{
            name: @backer.id.to_s + "-" + @backer.project.name.parameterize,
            unit_price: @backer.value_in_cents("mxn"),
            quantity: 1,
            antifraud_info: {
              project_id: @backer.project.id.to_s + "_" + @backer.project.slug,
              starts_at: @backer.project.publication_date.to_i,
              ends_at: @backer.project.expires_at.to_i,
              target_amount: (@backer.project.goal * 100).to_i
            }
          }],
          charges: [{
            payment_method: {
              type: "default"
            }
          }]
        }
        # we're creating an order but its called charge?
        charge = Conekta::Order.create(attributes)
        if charge.payment_status == "paid"
          # success scenario
          payment = charge.charges.first
          @backer.update_attributes({
            transaction_id: charge.id,
            gross_amount: (payment.amount / 100.0),
            gross_amount_currency_id: payment.currency,
            fee_amount: localize_charge_fee(payment.fee/100.0, @backer.project.currency),
            card_number: payment.payment_method.last4,
            card_brand: payment.payment_method.brand,
            card_name: payment.payment_method.name,
            card_issuer: payment.payment_method.issuer,
            expiration_month: payment.payment_method.exp_month,
            expiration_year: payment.payment_method.exp_year
          })
          @backer.confirm!
          send_successful_back_emails(@backer)
          @result[:status] = "approved"
          @result[:redirect] = success_conektum_path(@backer)
        else
          #fail scenario
          @backer.update_attributes transaction_id: charge.id, failure_code: charge.failure_code
          @result[:status] = "declined"
          FondeadoraMailer.failed_card_back(@backer).deliver_later!
        end
        #rescue  from earlier begin
      rescue Conekta::ErrorList => error_list
        # sets only last error in list.
        for error_detail in error_list.details do
          @result[:status] = "declined"
          @result[:message] = error_detail.message
        end
        # second rescue
      rescue Exception => e
        @result[:status] = "declined"
        @result[:message] = e.inspect
      end
    else
      # second fail scenario
      @result[:status] = "error"
      @result[:message] = @backer.errors.full_messages
    end
    render json: @result.to_json
  end

  def project
    @project ||= Project.friendly.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def load_current_rate
    # split
    currency = session["currency"]
    if currency
      @current_rate = Rails.cache.read(currency.downcase).to_f
      @current_currency = 1.to_money(currency).currency
    else
      @current_rate = @mxn_rate
      @current_currency =  1.to_money("mxn").currency
    end
  end

  def create_customer(token)
    return nil unless token
    # unnecesary begin
    begin
      # move attributes out, unnecesary variable
      customer = Conekta::Customer.create({
                                            name: current_user.name,
                                            email: current_user.email,
                                            payment_sources: [{
                                              type: "card",
                                              token_id: token
                                            }]
                                          })
      # can jsut return value from previous operations
      return customer
    rescue Conekta::ParameterValidationError => e
      return nil
    end
  end

end

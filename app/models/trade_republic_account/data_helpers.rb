# frozen_string_literal: true

module TradeRepublicAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("TradeRepublicAccount::DataHelpers - Failed to parse decimal: #{value.inspect} - #{e.message}")
      nil
    end

    # Trade Republic positions are keyed by ISIN. We resolve (or create) a
    # Security using the ISIN as the ticker, exactly like Indexa Capital — this
    # lets Sure's existing market-data providers track the live price going
    # forward (rather than us fetching quotes ourselves).
    def resolve_security(isin, position = {})
      ticker = isin.to_s.upcase.strip
      return nil if ticker.blank?

      security = Security.find_by(ticker: ticker)
      return security if security

      security_name = extract_security_name(position, ticker)

      Rails.logger.info "TradeRepublicAccount::DataHelpers - Creating security: ticker=#{ticker}, name=#{security_name}"

      Security.create!(ticker: ticker, name: security_name)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.error "TradeRepublicAccount::DataHelpers - Failed to create security #{ticker}: #{e.message}"
      Security.find_by(ticker: ticker)
    end

    def extract_security_name(position, fallback_ticker)
      data = position.respond_to?(:with_indifferent_access) ? position.with_indifferent_access : position
      name = data[:name] || data[:description]
      return fallback_ticker if name.blank? || name.is_a?(Hash)

      name = name.titleize if name == name.upcase && name.length > 4
      name
    end
end

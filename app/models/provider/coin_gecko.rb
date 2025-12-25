class Provider::CoinGecko < Provider
  include SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::CoinGecko::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  InvalidSymbolError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Cache duration for repeated requests (5 minutes)
  CACHE_DURATION = 5.minutes

  def initialize(api_key: nil)
    @api_key = api_key
    @cache_prefix = "coingecko"
  end

  def healthy?
    with_provider_response do
      response = client.get("/api/v3/ping")
      response.status == 200
    end.success?
  end

  def usage
    # CoinGecko doesn't expose usage API for free tier in a standard way
    with_provider_response do
      UsageData.new(
        used: 0,
        limit: 0,
        utilization: 0,
        plan: "Free" # or Pro if API key provided
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      cache_key = "search_#{symbol}"
      if cached_result = get_cached_result(cache_key)
        return cached_result
      end

      response = client.get("/api/v3/search") do |req|
        req.params["query"] = symbol
      end

      data = JSON.parse(response.body)
      coins = data.dig("coins") || []

      securities = coins.map do |coin|
        Security.new(
          symbol: coin["symbol"].upcase,
          name: coin["name"],
          logo_url: coin["thumb"],
          exchange_operating_mic: "CRYPTO",
          country_code: nil # Crypto is global
        )
      end

      cache_result(cache_key, securities)
      securities
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic: nil)
    with_provider_response do
      # For CoinGecko, we need the API ID, but we only have symbol.
      # We need to resolve symbol to ID first.
      coin_id = resolve_coin_id(symbol)
      raise InvalidSymbolError, "Could not resolve CoinGecko ID for #{symbol}" unless coin_id

      response = client.get("/api/v3/coins/#{coin_id}") do |req|
        req.params["tickers"] = false
        req.params["market_data"] = false
        req.params["community_data"] = false
        req.params["developer_data"] = false
        req.params["sparkline"] = false
      end

      data = JSON.parse(response.body)

      SecurityInfo.new(
        symbol: data["symbol"]&.upcase || symbol,
        name: data["name"],
        links: data.dig("links", "homepage")&.first,
        logo_url: data.dig("image", "large"),
        description: data.dig("description", "en"),
        kind: "cryptocurrency",
        exchange_operating_mic: "CRYPTO"
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      coin_id = resolve_coin_id(symbol)
      raise InvalidSymbolError, "Could not resolve CoinGecko ID for #{symbol}" unless coin_id

      # If date is today, use simple price endpoint
      if date == Date.current
        fetch_current_price(coin_id, symbol)
      else
        fetch_historical_price(coin_id, symbol, date)
      end
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      coin_id = resolve_coin_id(symbol)
      raise InvalidSymbolError, "Could not resolve CoinGecko ID for #{symbol}" unless coin_id

      # Convert dates to UNIX timestamps
      from_timestamp = start_date.beginning_of_day.to_i
      to_timestamp = end_date.end_of_day.to_i

      response = client.get("/api/v3/coins/#{coin_id}/market_chart/range") do |req|
        req.params["vs_currency"] = "usd"
        req.params["from"] = from_timestamp
        req.params["to"] = to_timestamp
      end

      data = JSON.parse(response.body)
      prices_data = data.dig("prices") || []

      # prices_data is [[timestamp, price], ...]
      # We need to group by day and take the last price (close) for that day
      # CoinGecko might return multiple prices per day depending on range

      mapped_prices = prices_data.map do |timestamp_ms, price|
        date = Time.at(timestamp_ms / 1000).to_date
        { date: date, price: price }
      end

      # Group by date and take the last one (close price logic)
      daily_prices = mapped_prices.group_by { |p| p[:date] }.map do |date, prices|
        # Take the last price of the day
        close_price = prices.last[:price]

        Price.new(
          symbol: symbol,
          date: date,
          price: close_price,
          currency: "USD",
          exchange_operating_mic: "CRYPTO"
        )
      end

      daily_prices.select { |p| p.date >= start_date && p.date <= end_date }
    end
  end

  private

    def base_url
      if @api_key.present?
        "https://pro-api.coingecko.com"
      else
        "https://api.coingecko.com"
      end
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 0.1,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        if @api_key.present?
          faraday.headers["x-cg-pro-api-key"] = @api_key
        end

        faraday.request :json
        faraday.response :raise_error
        faraday.options.timeout = 10
      end
    end

    def resolve_coin_id(symbol)
      # Resolve ID via search API (uncached specific call to get ID)
      response = client.get("/api/v3/search") do |req|
        req.params["query"] = symbol
      end

      data = JSON.parse(response.body)
      coins = data.dig("coins") || []

      # Exact symbol match
      exact = coins.find { |c| c["symbol"].upcase == symbol.upcase }
      exact ? exact["id"] : coins.first&.dig("id")
    end

    def fetch_current_price(coin_id, symbol)
      response = client.get("/api/v3/simple/price") do |req|
        req.params["ids"] = coin_id
        req.params["vs_currencies"] = "usd"
      end

      data = JSON.parse(response.body)
      price = data.dig(coin_id, "usd")

      raise InvalidSecurityPriceError, "No price found for #{symbol}" unless price

      Security::Price.new(
        security_id: nil, # populated by caller
        date: Date.current,
        price: price,
        currency: "USD"
      )
    end

    def fetch_historical_price(coin_id, symbol, date)
      # CoinGecko history endpoint uses dd-mm-yyyy
      formatted_date = date.strftime("%d-%m-%Y")

      response = client.get("/api/v3/coins/#{coin_id}/history") do |req|
        req.params["date"] = formatted_date
        req.params["localization"] = false
      end

      data = JSON.parse(response.body)
      price = data.dig("market_data", "current_price", "usd")

      raise InvalidSecurityPriceError, "No historical price found for #{symbol} on #{date}" unless price

      Security::Price.new(
        security_id: nil, # populated by caller
        date: date,
        price: price,
        currency: "USD"
      )
    end

    # ================================
    #           Caching
    # ================================

    def get_cached_result(key)
      full_key = "#{@cache_prefix}_#{key}"
      Rails.cache.read(full_key)
    end

    def cache_result(key, data)
      full_key = "#{@cache_prefix}_#{key}"
      Rails.cache.write(full_key, data, expires_in: CACHE_DURATION)
    end
end

# Debug Crypto Sync
account_id = "0213fbc4-b7ef-43b9-b02e-22dd68fa0792"
account = Account.find(account_id)
puts "Account: #{account.name} (#{account.id})"

trade = account.trades.joins(:security).find_by(securities: { ticker: "ETH" })
unless trade
  puts "Trade not found!"
  exit
end

security = trade.security
puts "Security: #{security.ticker} (ID: #{security.id})"
puts "Exchange MIC: #{security.exchange_operating_mic}"

puts "Cleaning up existing prices for clean test..."
Security::Price.where(security: security).delete_all

puts "Running MarketDataImporter..."
importer = Account::MarketDataImporter.new(account)
importer.import_all

prices_count = Security::Price.where(security: security).count
puts "Prices found after import: #{prices_count}"

if prices_count == 0
  puts "ERROR: No prices imported. Debugging Importer..."
  provider = Provider::Registry.get_provider(:coin_gecko)
  start_date = Date.current - 5.days
  end_date = Date.current

  puts "Resolving CoinGecko ID for #{security.ticker}..."
  # Use send to call private method or just rely on public search
  # Testing fetch_security_prices directly

  puts "Fetching prices from CoinGecko for #{start_date} to #{end_date}..."
  response = provider.fetch_security_prices(
    symbol: security.ticker,
    exchange_operating_mic: security.exchange_operating_mic,
    start_date: start_date,
    end_date: end_date
  )

  if response.success?
    puts "Response Success: true"
  else
    puts "Response Success: false"
    puts "Error Message: #{response.error.message}"
    if response.error.respond_to?(:details)
      puts "Error Details: #{response.error.details}"
    end
  end
end

puts "Running Balance::Materializer..."
Balance::Materializer.new(account, strategy: :forward).materialize_balances

puts "Checking Holdings..."
holdings = account.holdings.where(security: security).order(date: :asc).last(5)
holdings.each do |h|
  puts "Holding: #{h.security.ticker}, Date: #{h.date}, Qty: #{h.qty}, Price: #{h.price}, Amount: #{h.amount}"
end

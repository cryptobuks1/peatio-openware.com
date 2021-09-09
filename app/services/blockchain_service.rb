# frozen_string_literal: true

class BlockchainService
  Error = Class.new(StandardError)
  BalanceLoadError = Class.new(StandardError)

  attr_reader :blockchain, :whitelisted_smart_contract, :currencies, :adapter

  def initialize(blockchain)
    @blockchain = blockchain
    @blockchain_currencies = blockchain.blockchain_currencies.deposit_enabled
    @currencies = @blockchain_currencies.pluck(:currency_id).uniq
    @whitelisted_addresses = blockchain.whitelisted_smart_contracts.active
    @adapter = Peatio::Blockchain.registry[blockchain.client.to_sym].new
    @adapter.configure(server: @blockchain.server,
                       currencies: @blockchain_currencies.map(&:to_blockchain_api_settings),
                       whitelisted_addresses: @whitelisted_addresses)
  end

  def latest_block_number
    @latest_block_number ||= @adapter.latest_block_number
  end

  def load_balance!(address, currency_id)
    @adapter.load_balance_of_address!(address, currency_id)
  rescue Peatio::Blockchain::Error => e
    report_exception(e)
    raise BalanceLoadError
  end

  def case_sensitive?
    @adapter.features[:case_sensitive]
  end

  def supports_cash_addr_format?
    @adapter.features[:cash_addr_format]
  end

  def fetch_transaction(transaction)
    tx = Peatio::Transaction.new(currency_id: transaction.currency_id,
                                 hash: transaction.txid,
                                 to_address: transaction.rid,
                                 amount: transaction.amount)
    if @adapter.respond_to?(:fetch_transaction)
      @adapter.fetch_transaction(tx)
    else
      tx
    end
  end

  def process_block(block_number)
    block = @adapter.fetch_block!(block_number)
    deposits = filter_deposit_txs(block)
    withdrawals = filter_withdrawals(block)
    process_pending_deposit_txs(deposits[:existing_deposits_blockchain_txs], deposits[:existing_deposits_db_txs])
    # TODO: Process Transactions with `pending` status

    accepted_deposits = []
    ActiveRecord::Base.transaction do
      accepted_deposits = deposits[:new_deposits_blockchain_txs].map(&method(:update_or_create_deposit)).compact
      withdrawals.each(&method(:update_withdrawal))
    end
    accepted_deposits.each(&:process!)
    block
  end

  # Resets current cached state.
  def reset!
    @latest_block_number = nil
  end

  def update_height(block_number)
    raise Error, "#{blockchain.name} height was reset." if blockchain.height != blockchain.reload.height

    # NOTE: We use update_column to not change updated_at timestamp
    # because we use it for detecting blockchain configuration changes see Workers::Daemon::Blockchain#run.
    blockchain.update_column(:height, block_number) if latest_block_number - block_number >= blockchain.min_confirmations
  end

  private

  # Filters deposit, fee and deposit_collection txs
  # This method is so complicated to reduce amount of database interactions during deposit processing
  def filter_deposit_txs(block)
    # Filter transaction source/destination addresses
    addresses = PaymentAddress.where(wallet: Wallet.deposit.with_currency(@currencies.codes),
                                     address: block.transactions.map(&:to_address)).pluck(:address)

    Wallet.with_currency(@currencies.codes).pluck(:address).map do |addr|
      addresses << addr.downcase
    end

    # Select transactions, that are related to the platform
    deposit_related_txs = block.select { |transaction| transaction.to_address.in?(addresses) }

    # Select transactions in database
    existing_db_txs = Transaction.where(txid: deposit_related_txs.map(&:hash))
    existing_db_txs_ids = existing_db_txs.pluck(:txid)

    # Partition returns two arrays, the first containing the elements of enum
    # for which the block evaluates to true, the second containing the rest.
    #
    # This is not really safe, because tx and prebuild_tx can be recognized as a new deposit
    existing_deposits_txs, new_deposits_txs = deposit_related_txs.partition do |tx|
      tx.hash.in?(existing_db_txs_ids)
    end

    {
      new_deposits_blockchain_txs: new_deposits_txs,
      existing_deposits_blockchain_txs: existing_deposits_txs,
      existing_deposits_db_txs: existing_db_txs
    }
  end

  # Deposit in state processing
  # There is no Transaction yet
  # no actions

  # Deposit in state fee_collecting
  # check tx state
  # if succeed change state to fee_processing and change state of db_tx to succeed

  # Deposit in state fee_processing
  # There is no Transaction yet
  # no actions

  # Deposit in state collecting
  # check tx state
  # if succeed change state to collected and change state of db_tx to succeed
  def process_pending_deposit_txs(block_txs, db_txs)
    db_txs.each do |db_tx|
      next unless db_tx.pending?

      block_tx = block_txs.find { |tx| tx if db_tx.txid == tx.hash }
      next unless block_tx

      deposit = db_tx.reference
      next unless deposit.fee_collecting? || deposit.collecting?

      block_tx = adapter.fetch_transaction(block_tx) if @adapter.respond_to?(:fetch_transaction) && ( block_tx.fee.blank? || block_tx.status.pending? )

      db_tx.fee = block_tx.fee
      # db_tx.fee_currency_id = block_tx.fee_currency_id
      db_tx.block_number = block_tx.block_number
      db_tx.save!

      # BSC can return success only after fetch transaction
      if block_tx.success?
        db_tx.confirm!

        if deposit.fee_collecting? && db_tx.kind == 'tx_prebuild'
          deposit.fee_process! if deposit.fee_collecting?
        end

        if deposit.collecting? && db_tx.kind == 'tx'
          updated_spread = deposit.spread.map do |tx|
            tx[:status] = 'succeed' if tx[:hash] == block_tx.hash
            tx
          end

          deposit.update(spread: updated_spread)
          deposit.dispatch! if deposit.spread.map{|t| t[:status]}.uniq.eql?(['succeed'])
        end

      elsif block_tx.failed?
        db_tx.fail!
        deposit.err! 'Fee collection transaction failed' if db_tx.kind == 'tx_prebuild'
        deposit.err! 'Collection transaction failed' if db_tx.kind == 'tx'

      else
      #   What should we do here?
      # Is it possible?
      end
    end
  end

  def filter_withdrawals(block)
    # TODO: Process addresses in batch in case of huge number of confirming withdrawals.
    withdraw_txids = Withdraws::Coin.confirming.where(currency: @currencies,
                                                      blockchain_key: @blockchain.key).pluck(:txid)
    block.select { |transaction| transaction.hash.in?(withdraw_txids) }
  end

  def update_or_create_deposit(transaction)
    blockchain_currency = BlockchainCurrency.find_network(@blockchain.key, transaction.currency_id)

    if transaction.amount < blockchain_currency.min_deposit_amount
      # Currently we just skip tiny deposits.
      Rails.logger.info do
        "Skipped deposit with txid: #{transaction.hash} with amount: #{transaction.hash}"\
        " to #{transaction.to_address} in block number #{transaction.block_number}"
      end
      return
    end

    # Fetch transaction from a blockchain that has `pending` status.
    transaction = adapter.fetch_transaction(transaction) if @adapter.respond_to?(:fetch_transaction) && transaction.status.pending?
    return unless transaction.status.success?

    address = PaymentAddress.find_by(wallet: Wallet.deposit_wallets(transaction.currency_id, @blockchain.key), address: transaction.to_address)
    return if address.blank?

    # Skip deposit tx if there is tx for deposit collection process
    # TODO: select only pending transactions
    tx_collect = Transaction.where(txid: transaction.hash, reference_type: 'Deposit')
    return if tx_collect.present?

    if transaction.from_addresses.blank? && adapter.respond_to?(:transaction_sources)
      transaction.from_addresses = adapter.transaction_sources(transaction)
    end

    deposit =
      Deposits::Coin.find_or_create_by!(
        currency_id: transaction.currency_id,
        txid: transaction.hash,
        txout: transaction.txout,
        blockchain_key: @blockchain.key
      ) do |d|
        d.address = transaction.to_address
        d.amount = transaction.amount
        d.member = address.member
        d.from_addresses = transaction.from_addresses
        d.block_number = transaction.block_number
      end

    deposit.update_column(:block_number, transaction.block_number) if deposit.block_number != transaction.block_number
    # Manually calculating deposit confirmations, because blockchain height is not updated yet.
    if latest_block_number - deposit.block_number >= @blockchain.min_confirmations && deposit.accept!
      deposit
    else
      nil
    end
  end

  def update_withdrawal(transaction)
    withdrawal =
      Withdraws::Coin.confirming
        .find_by(currency_id: transaction.currency_id, blockchain_key: @blockchain.key, txid: transaction.hash)

    # Skip non-existing in database withdrawals.
    if withdrawal.blank?
      Rails.logger.info { "Skipped withdrawal: #{transaction.hash}." }
      return
    end

    withdrawal.update_column(:block_number, transaction.block_number)

    # Fetch transaction from a blockchain that has `pending` status.
    transaction = adapter.fetch_transaction(transaction) if @adapter.respond_to?(:fetch_transaction) && transaction.status.pending?

    db_tx = Transaction.find_by(txid: transaction.hash)
    db_tx.update!(fee: transaction.fee, block_number: transaction.block_number, fee_currency_id: transaction.fee_currency_id)

    # Manually calculating withdrawal confirmations, because blockchain height is not updated yet.
    if transaction.status.failed?
      withdrawal.fail!
      db_tx.fail!
    elsif transaction.status.success? && latest_block_number - withdrawal.block_number >= @blockchain.min_confirmations
      withdrawal.success!
      db_tx.confirm!
    end
  end
end

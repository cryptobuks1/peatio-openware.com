# frozen_string_literal: true

describe Workers::Daemons::Deposit do
  let(:btc_deposit) { create(:deposit, :deposit_btc) }
  let(:eth_deposit) { create(:deposit, :deposit_eth) }
  let(:trst_deposit) { create(:deposit, :deposit_trst) }

  let(:collected_spread) do
    spread.each_with_index.map do |s, i|
      s.merge(hash: "hash-#{i}")
    end
  end

  subject { Workers::Daemons::Deposit.new }

  context 'collecting btc deposit' do
    before do
      btc_deposit.accept!
      btc_deposit.process!
      btc_deposit.update!(updated_at: Time.now - 20.minutes)
      transactions = collected_spread.map { |s| Peatio::Transaction.new(s) }
      WalletService.any_instance
                   .expects(:collect_deposit!)
                   .with(instance_of(Deposits::Coin), anything)
                   .returns(transactions)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one btc deposit' do
      subject.process
      expect(btc_deposit.reload.collecting?).to be_truthy
    end
  end

  context 'collecting eth deposit' do
    before do
      eth_deposit.accept!
      eth_deposit.process!
      eth_deposit.update!(updated_at: Time.now - 20.minutes)
    end

    before do
      transactions = collected_spread.map { |s| Peatio::Transaction.new(s) }
      WalletService.any_instance
                   .expects(:collect_deposit!)
                   .with(instance_of(Deposits::Coin), anything)
                   .returns(transactions)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one eth deposit' do
      subject.process
      expect(eth_deposit.reload.collecting?).to be_truthy
    end
  end

  context 'collect fee for trst deposit' do
    before do
      trst_deposit.accept!
      trst_deposit.process!
      trst_deposit.update!(updated_at: Time.now - 20.minutes)
    end

    before do
      transactions = collected_spread.map { |s| Peatio::Transaction.new(s) }
      WalletService.any_instance
                   .expects(:deposit_collection_fees!)
                   .with(instance_of(Deposits::Coin), anything)
                   .returns(transactions)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one trst deposit' do
      subject.process
      expect(trst_deposit.reload.fee_collecting?).to be_truthy
    end
  end

  context 'collect trst deposit' do
    let!(:transaction) { Transaction.create!(txid: trst_deposit.txid, reference: trst_deposit, kind: 'tx_prebuild', from_address: 'fake_address', to_address: trst_deposit.address, blockchain_key: trst_deposit.blockchain_key, status: :pending, currency_id: trst_deposit.currency_id) }

    before do
      trst_deposit.accept!
      trst_deposit.process!
      trst_deposit.process_fee_collection!
      trst_deposit.confirm_fee_collection!
      trst_deposit.update!(updated_at: Time.now - 20.minutes)
    end

    before do
      transactions = collected_spread.map { |s| Peatio::Transaction.new(s) }
      WalletService.any_instance
                   .expects(:collect_deposit!)
                   .with(instance_of(Deposits::Coin), anything)
                   .returns(transactions)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one trst deposit' do
      subject.process
      expect(trst_deposit.reload.collecting?).to be_truthy
    end
  end

  context 'error raised on collection step' do
    before do
      btc_deposit.accept!
      btc_deposit.process!
      btc_deposit.update!(updated_at: Time.now - 20.minutes)
      WalletService.any_instance
                   .expects(:collect_deposit!)
                   .with(instance_of(Deposits::Coin), anything)
                   .raises(StandardError.new)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one btc deposit' do
      subject.process
      expect(btc_deposit.reload.processing?).to be_truthy
    end
  end

  context 'error raised on collection fee step' do
    before do
      eth_deposit.accept!
      eth_deposit.process!
      eth_deposit.update!(updated_at: Time.now - 20.minutes)
      WalletService.any_instance
                   .expects(:deposit_collection_fees!)
                   .with(instance_of(Deposits::Coin), anything)
                   .raises(StandardError.new)
    end

    let(:spread) do
      [{ to_address: 'to-address', amount: 0.1, status: 'pending' }]
    end

    it 'process one eth deposit' do
      subject.process
      expect(eth_deposit.reload.errored?).to be_truthy
    end
  end
end

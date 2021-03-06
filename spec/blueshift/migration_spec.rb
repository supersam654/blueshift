require 'spec_helper'

describe Blueshift::Migration do
  let(:up_block) { proc { 'up' } }
  let(:down_block) { proc { 'down' } }
  let!(:redup_block) { proc { 'redup' } }
  let!(:reddown_block) { proc { 'reddown' } }

  before do
    Sequel::Migration.descendants.clear
  end

  subject do
    up_blk = up_block
    down_blk = down_block
    redup_blk = redup_block
    reddown_blk = reddown_block

    Blueshift.migration do
      up &up_blk
      down &down_blk
      redup &redup_blk
      reddown &reddown_blk
    end
  end

  describe '.new' do
    it 'should assign the redshift commands individually' do
      expect(subject.postgres_migration.up).to eq up_block
      expect(subject.redshift_migration.up).to eq redup_block
      expect(subject.postgres_migration.down).to eq down_block
      expect(subject.redshift_migration.down).to eq reddown_block
    end

    it 'appends the migration to the list of Sequel Migrations' do
      expect(Sequel::Migration.descendants).to eq([subject])
    end

    context 'when either redup or reddown is not declared' do
      subject { Blueshift.migration { up {}; down {} } }
      it 'should raise an exception' do
        expect { subject }.to raise_error(ArgumentError, 'must declare blocks for up, down, redup, and reddown')
      end
    end
  end

  describe '#apply' do
    context 'when applying to a Redshift database' do
      it 'should call the Redshift migrations' do
        expect(subject.redshift_migration).to receive(:apply).with(Blueshift::REDSHIFT_DB, :up)
        subject.apply(Blueshift::REDSHIFT_DB, :up)
      end

      it 'does not apply the Postgres migration commands' do
        expect(subject.postgres_migration).to_not receive(:apply)
        subject.apply(Blueshift::REDSHIFT_DB, :up)
      end
    end

    context 'when applying to a Postgres database' do
      it 'should call the Redshift migrations' do
        expect(subject.postgres_migration).to receive(:apply).with(Blueshift::POSTGRES_DB, :down)
        subject.apply(Blueshift::POSTGRES_DB, :down)
      end

      it 'does not apply the Redshift migration commands' do
        expect(subject.redshift_migration).to_not receive(:apply)
        subject.apply(Blueshift::POSTGRES_DB, :up)
      end
    end
  end

  describe '#no_transaction' do
    it 'should disable the use of transactions' do
      expect { subject.no_transaction }.to change(subject, :use_transactions).to(false)
    end
  end

  describe '.run_both!' do
    it 'should run the migrations for both Postgres and Redshift' do
      expect(Sequel::Migrator).to receive(:run).ordered do |db, dir|
        expect(db).to eq(Blueshift::POSTGRES_DB)
        expect(dir).to end_with('db/migrations')
      end

      expect(Sequel::Migrator).to receive(:run).ordered do |db, dir|
        expect(db).to eq(Blueshift::REDSHIFT_DB)
        expect(dir).to end_with('db/migrations')
      end
      Blueshift::Migration.run_both!
    end

    it 'should work' do
      Blueshift::POSTGRES_DB[:schema_migrations].delete if Blueshift::POSTGRES_DB.table_exists?(:schema_migrations)
      Blueshift::REDSHIFT_DB[:schema_migrations].delete if Blueshift::REDSHIFT_DB.table_exists?(:schema_migrations)
      FileUtils.mkdir_p('db/migrations')
      File.open('db/migrations/20011225115959_create_dummy.rb', 'w') { |f| f << 'Blueshift.migration { up {}; down {}; redup {}; reddown {} }' }
      expect { Blueshift::Migration.run_both! }.to_not raise_error
    end
  end

  describe '.insert_into_schema_migrations' do
    let(:migrations_count) {  Dir["spec/support/db/migrations/*"].count }

    it 'writes to the schema migrations table' do
      expect_any_instance_of(Sequel::Postgres::Dataset).to receive(:insert).exactly(migrations_count).times
      Blueshift::Migration.insert_into_schema_migrations(Blueshift::POSTGRES_DB)
    end
  end

  describe '.rollback!' do
    it 'should rollback the latest applied migration for Postgres' do
      Blueshift::Migration.run_pg!

      expect(Blueshift::Migration).to receive(:run_pg!).with(target: 20160601192854)
      Blueshift::Migration.rollback!(:pg)
    end

    it 'should rollback the latest applied migration for Redshift' do
      Blueshift::Migration.run_redshift!

      expect(Blueshift::Migration).to receive(:run_redshift!).with(target: 20160601192854)
      Blueshift::Migration.rollback!(:redshift)
    end

    context 'when there are newer, unapplied migration files in the directory' do
      it 'should only rollback the latest applied migration' do
        Blueshift::Migration.run_pg!(target: 20160601192854)

        expect(Blueshift::Migration).to receive(:run_pg!).with(target: 0)
        Blueshift::Migration.rollback!(:pg)
      end
    end
  end
end

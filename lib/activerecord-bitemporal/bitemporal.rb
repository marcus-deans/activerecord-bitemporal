# frozen_string_literal: true

require "activerecord-bitemporal/bitemporal_checker"
module ActiveRecord
  module Bitemporal
    using BitemporalChecker

    module Optionable
      def bitemporal_option
        ::ActiveRecord::Bitemporal.merge_by(bitemporal_option_storage)
      end

      def bitemporal_option_merge!(other)
        self.bitemporal_option_storage = bitemporal_option.merge other
      end

      def with_bitemporal_option(**opt)
        tmp_opt = bitemporal_option_storage
        self.bitemporal_option_storage = tmp_opt.merge(opt)
        yield self
      ensure
        self.bitemporal_option_storage = tmp_opt
      end
    private
      def bitemporal_option_storage
        @bitemporal_option_storage ||= {}
      end

      def bitemporal_option_storage=(value)
        @bitemporal_option_storage = value
      end
    end

    # Add Optionable to Bitemporal
    # Example:
    # ActiveRecord::Bitemporal.valid_at("2018/4/1") {
    #   # in valid_datetime is "2018/4/1".
    # }
    module ::ActiveRecord::Bitemporal
      class Current < ActiveSupport::CurrentAttributes
        attribute :option
      end

      class << self
        include Optionable

        def valid_at(datetime, &block)
          with_bitemporal_option(ignore_valid_datetime: false, valid_datetime: datetime, &block)
        end

        def valid_at!(datetime, &block)
          with_bitemporal_option(ignore_valid_datetime: false, valid_datetime: datetime, force_valid_datetime: true, &block)
        end

        def valid_datetime
          bitemporal_option[:valid_datetime]&.in_time_zone
        end

        def valid_date
          valid_datetime&.to_date
        end

        def ignore_valid_datetime(&block)
          with_bitemporal_option(ignore_valid_datetime: true, valid_datetime: nil, &block)
        end

        def transaction_at(datetime, &block)
          with_bitemporal_option(ignore_transaction_datetime: false, transaction_datetime: datetime, &block)
        end

        def transaction_at!(datetime, &block)
          with_bitemporal_option(ignore_transaction_datetime: false, transaction_datetime: datetime, force_transaction_datetime: true, &block)
        end

        def transaction_datetime
          bitemporal_option[:transaction_datetime]&.in_time_zone
        end

        def ignore_transaction_datetime(&block)
          with_bitemporal_option(ignore_transaction_datetime: true, transaction_datetime: nil, &block)
        end

        def bitemporal_at(datetime, &block)
          transaction_at(datetime) { valid_at(datetime, &block) }
        end

        def bitemporal_at!(datetime, &block)
          transaction_at!(datetime) { valid_at!(datetime, &block) }
        end

        def merge_by(option)
          option_ = option.dup
          if bitemporal_option_storage[:force_valid_datetime]
            option_.merge!(valid_datetime: bitemporal_option_storage[:valid_datetime])
          end

          if bitemporal_option_storage[:force_transaction_datetime]
            option_.merge!(transaction_datetime: bitemporal_option_storage[:transaction_datetime])
          end

          bitemporal_option_storage.merge(option_)
        end
      private
        def bitemporal_option_storage
          Current.option ||= {}
        end

        def bitemporal_option_storage=(value)
          Current.option = value
        end
      end
    end

    module Relation
      module BitemporalIdAsPrimaryKey # :nodoc:
        private

        # Generate a method that temporarily changes the primary key to
        # bitemporal_id for localizing the effect of the change to only the
        # method specified by `name`.
        #
        # DO NOT use this method outside of this module.
        def use_bitemporal_id_as_primary_key(name) # :nodoc:
          module_eval <<~RUBY, __FILE__, __LINE__ + 1
            def #{name}(...)
              all.spawn.yield_self { |relation|
                def relation.primary_key
                  bitemporal_id_key
                end
                relation.method(:#{name}).super_method.call(...)
              }
            end
          RUBY
        end
      end
      extend BitemporalIdAsPrimaryKey

      module Finder
        extend BitemporalIdAsPrimaryKey

        use_bitemporal_id_as_primary_key :find

        if ActiveRecord.version >= Gem::Version.new("8.0.0")
          use_bitemporal_id_as_primary_key :exists?
        end

        def find_at_time!(datetime, *ids)
          valid_at(datetime).find(*ids)
        end

        def find_at_time(datetime, *ids)
          find_at_time!(datetime, *ids)
        rescue ActiveRecord::RecordNotFound
          expects_array = ids.first.kind_of?(Array) || ids.size > 1
          expects_array ? [] : nil
        end
      end
      include Finder

      if ActiveRecord.version >= Gem::Version.new("8.0.0")
        use_bitemporal_id_as_primary_key :ids
      end

      def build_arel(*)
        ActiveRecord::Bitemporal.with_bitemporal_option(**bitemporal_option) {
          super
        }
      end

      def load
        return super if loaded?

        # このタイミングで先読みしているアソシエーションが読み込まれるので時間を固定
        records = ActiveRecord::Bitemporal.with_bitemporal_option(**bitemporal_option) { super }

        return records if records.empty?

        valid_datetime_ = valid_datetime
        if ActiveRecord::Bitemporal.valid_datetime.nil? && (bitemporal_value[:with_valid_datetime].nil? || bitemporal_value[:with_valid_datetime] == :default_scope || valid_datetime_.nil?)
          valid_datetime_ = nil
        end

        transaction_datetime_ = transaction_datetime
        if ActiveRecord::Bitemporal.transaction_datetime.nil? && (bitemporal_value[:with_transaction_datetime].nil? || bitemporal_value[:with_transaction_datetime] == :default_scope || transaction_datetime_.nil?)
          transaction_datetime_ = nil
        end

        return records if valid_datetime_.nil? && transaction_datetime_.nil?

        records.each do |record|
          record.send(:bitemporal_option_storage)[:valid_datetime] = valid_datetime_ if valid_datetime_
          record.send(:bitemporal_option_storage)[:transaction_datetime] = transaction_datetime_ if transaction_datetime_
        end
      end

      # Use original primary_key for Active Record 8.0+ as much as possible
      # to avoid issues with patching primary_key of AR::Relation globally.
      if ActiveRecord.version < Gem::Version.new("8.0.0")
        def primary_key
          bitemporal_id_key
        end
      end
    end

    # create, update, destroy に処理をフックする
    module Persistence
      module EachAssociation
        refine ActiveRecord::Persistence do
          def each_association(
            deep: false,
            ignore_associations: [],
            only_cached: false,
            &block
          )
            klass = self.class
            enum = Enumerator.new { |y|
              reflections = klass.reflect_on_all_associations
              reflections.each { |reflection|
                next if only_cached && !association_cached?(reflection.name)

                associations = reflection.collection? ? public_send(reflection.name) : [public_send(reflection.name)]
                associations.compact.each { |asso|
                  next if ignore_associations.include? asso
                  ignore_associations << asso
                  y << asso
                  asso.each_association(deep: deep, ignore_associations: ignore_associations, only_cached: only_cached) { |it| y << it } if deep
                }
              }
              self
            }
            enum.each(&block)
          end
        end
      end
      using EachAssociation

      module PersistenceOptionable
        include Optionable

        def force_update(&block)
          with_bitemporal_option(force_update: true, &block)
        end

        def force_update?
          bitemporal_option[:force_update].present?
        end

        def valid_at(datetime, &block)
          with_bitemporal_option(valid_datetime: datetime, &block)
        end

        def transaction_at(datetime, &block)
          with_bitemporal_option(transaction_datetime: datetime, &block)
        end

        def bitemporal_at(datetime, &block)
          transaction_at(datetime) { valid_at(datetime, &block) }
        end

        def bitemporal_option_merge_with_association!(other)
          bitemporal_option_merge!(other)

          # Only cached associations will be walked for performance issues
          each_association(deep: true, only_cached: true).each do |association|
            next unless association.respond_to?(:bitemporal_option_merge!)
            association.bitemporal_option_merge!(other)
          end
        end

        def valid_datetime
          bitemporal_option[:valid_datetime]&.in_time_zone
        end

        def valid_date
          valid_datetime&.to_date
        end

        def transaction_datetime
          bitemporal_option[:transaction_datetime]&.in_time_zone
        end

        # Cascade Correction: Correct a retroactive value while preserving future changes
        #
        # @param valid_from [Time, Date, String] When the correction starts being true
        # @param valid_to [Time, Date, String, nil] When the correction ends (optional)
        #   - If specified: Correct exactly [valid_from, valid_to), resume timeline at valid_to
        #   - If omitted: Correct from valid_from to next change point, preserve all future changes
        # @param attributes [Hash] The corrected attribute values
        # @return [Boolean] true if successful
        def correct(valid_from:, valid_to: nil, **attributes)
          valid_from = valid_from.in_time_zone if valid_from.respond_to?(:in_time_zone)
          valid_to = valid_to.in_time_zone if valid_to.respond_to?(:in_time_zone)

          if valid_to && valid_to <= valid_from
            raise ArgumentError, "valid_to (#{valid_to}) must be greater than valid_from (#{valid_from})"
          end

          with_bitemporal_option(correcting: true) do
            _correct_record(valid_from: valid_from, valid_to: valid_to, attributes: attributes)
          end
        end

        # Shift Genesis: Move the start of an entity's timeline forward or backward
        #
        # @param new_valid_from [Time, Date, String] The new start date for the entity's timeline
        # @return [Boolean] true if successful
        def shift_genesis(new_valid_from:)
          new_valid_from = new_valid_from.in_time_zone if new_valid_from.respond_to?(:in_time_zone)
          _shift_genesis_record(new_valid_from: new_valid_from)
        end

        def correcting?
          bitemporal_option[:correcting].present?
        end
      end
      include PersistenceOptionable

      using Module.new {
        refine Persistence do
          def build_new_instance
            self.class.new.tap { |it|
              (self.class.column_names - %w(id type created_at updated_at) - bitemporal_ignore_update_columns.map(&:to_s)).each { |name|
                # 生のattributesの値でなく、ラッパーメソッド等を考慮してpublic_send(name)する
                it.public_send("#{name}=", public_send(name))
              }
            }
          end

          def has_column?(name)
            self.class.column_names.include? name.to_s
          end

          def assign_transaction_to(value)
            if has_column?(:deleted_at)
              assign_attributes(transaction_to: value, deleted_at: value)
            else
              assign_attributes(transaction_to: value)
            end
          end

          def update_transaction_to(value)
            if has_column?(:deleted_at)
              update_columns(transaction_to: value, deleted_at: value)
            else
              update_columns(transaction_to: value)
            end
          end

        end

        refine ActiveRecord::Base do
          # MEMO: Do not copy bitemporal internal status
          def dup(*)
            super.tap { |itself|
              itself.instance_exec do
                @_swapped_id_previously_was = nil
                @_swapped_id = nil
                @previously_force_updated = false
              end unless itself.frozen?
            }
          end
        end
      }

      def _create_record(attribute_names = self.attribute_names)
        bitemporal_assign_initialize_value(valid_datetime: self.valid_datetime)

        ActiveRecord::Bitemporal.valid_at!(self[valid_from_key]) {
          super()
        }
      end

      def save(**)
        ActiveRecord::Base.transaction(requires_new: true) do
          self.class.where(bitemporal_id: self.id).lock!.pluck(:id) if self.id
          super
        end
      end

      def save!(**)
        ActiveRecord::Base.transaction(requires_new: true) do
          self.class.where(bitemporal_id: self.id).lock!.pluck(:id) if self.id
          super
        end
      end

      def _update_row(attribute_names, attempted_action = 'update')
        current_valid_record, before_instance, after_instance = bitemporal_build_update_records(valid_datetime: self.valid_datetime, force_update: self.force_update?)

        # MEMO: このメソッドに来るまでに validation が発動しているので、以後 validate は考慮しなくて大丈夫
        ActiveRecord::Base.transaction(requires_new: true) do
          current_valid_record&.update_transaction_to(current_valid_record.transaction_to)
          before_instance&.save_without_bitemporal_callbacks!(validate: false)
          # NOTE: after_instance always exists
          after_instance.save_without_bitemporal_callbacks!(validate: false)
          @previously_force_updated = self.force_update?

          # update 後に新しく生成したインスタンスのデータを移行する
          @_swapped_id_previously_was = swapped_id
          @_swapped_id = after_instance.swapped_id
          self[valid_from_key] = after_instance[valid_from_key]
          self[valid_to_key] = after_instance[valid_to_key]
          self.transaction_from = after_instance.transaction_from
          self.transaction_to = after_instance.transaction_to

          1
        # MEMO: Must return false instead of nil, if `#_update_row` failure.
        end || false
      end

      def destroy(force_delete: false, operated_at: nil)
        return super() if force_delete

        ActiveRecord::Base.transaction(requires_new: true) do
          @destroyed = false
          _run_destroy_callbacks {
            operated_at ||= Time.current
            target_datetime = valid_datetime || operated_at

            duplicated_instance = self.class.find_at_time(target_datetime, self.id).dup

            @destroyed = update_transaction_to(operated_at)
            @previously_force_updated = force_update?

            # force_update の場合は削除時の状態の履歴を残さない
            unless force_update?
              # 削除時の状態を履歴レコードとして保存する
              duplicated_instance[valid_to_key] = target_datetime
              duplicated_instance.transaction_from = operated_at
              duplicated_instance.save_without_bitemporal_callbacks!(validate: false)
              if @destroyed
                @_swapped_id_previously_was = swapped_id
                @_swapped_id = duplicated_instance.swapped_id
                self[valid_from_key] = duplicated_instance[valid_from_key]
                self[valid_to_key] = duplicated_instance[valid_to_key]
                self.transaction_from = duplicated_instance.transaction_from
                self.transaction_to = duplicated_instance.transaction_to
              end
            end
          }
          raise ActiveRecord::RecordInvalid unless @destroyed

          self
        end
      rescue => e
        @destroyed = false
        @_association_destroy_exception = ActiveRecord::RecordNotDestroyed.new("Failed to destroy the record: class=#{e.class}, message=#{e.message}", self)
        @_association_destroy_exception.set_backtrace(e.backtrace)
        false
      end

      # MEMO: Since Rails 7.1 #_find_record refers to a record with find_by!(@primary_key => id)
      #       But if @primary_key is "id", it can't refer to the intended record, so we hack it to refer to the record based on self.class.bitemporal_id_key
      #       see: https://github.com/rails/rails/blob/v7.1.0/activerecord/lib/active_record/persistence.rb#L1152-#L1171
      def _find_record(*)
        tmp_primary_key, @primary_key = @primary_key, self.class.bitemporal_id_key
        super
      ensure
        @primary_key = tmp_primary_key
      end

      module ::ActiveRecord::Persistence
        # MEMO: Must be override ActiveRecord::Persistence#reload
        alias_method :active_record_bitemporal_original_reload, :reload unless method_defined? :active_record_bitemporal_original_reload
        def reload(options = nil)
          return active_record_bitemporal_original_reload(options) unless self.class.bi_temporal_model?

          self.class.connection.clear_query_cache

          fresh_object =
            ActiveRecord::Bitemporal.with_bitemporal_option(**bitemporal_option) {
              if apply_scoping?(options)
                _find_record(options)
              else
                self.class.unscoped { self.class.bitemporal_default_scope.scoping { _find_record(options) } }
              end
            }

          @association_cache = fresh_object.instance_variable_get(:@association_cache)
          @attributes = fresh_object.instance_variable_get(:@attributes)
          @new_record = false
          @previously_new_record = false
          # NOTE: Hook to copying swapped_id
          @_swapped_id_previously_was = nil
          @_swapped_id = fresh_object.swapped_id
          @previously_force_updated = false
          self
        end
      end

      private

      # Cascade Correction: Main implementation
      def _correct_record(valid_from:, valid_to:, attributes:)
        current_time = Time.current

        ActiveRecord::Base.transaction(requires_new: true) do
          # Lock all records for this entity
          self.class.where(bitemporal_id: bitemporal_id).lock!.pluck(:id)

          # 1. Find all affected records (current knowledge, from valid_from onward)
          affected_records = find_affected_records_for_correction(valid_from)

          # Check if any record actually contains valid_from
          # (valid_from must fall within an existing record's valid time range)
          containing_record = affected_records.find { |r|
            r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
          }

          if containing_record.nil?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} at #{valid_from}",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          # 2. Determine effective valid_to (for unbounded corrections)
          effective_valid_to = valid_to || determine_correction_end(valid_from, affected_records)

          # 3. Build the new timeline
          records_to_close, new_timeline = bitemporal_build_cascade_correction_records(
            affected_records: affected_records,
            valid_from: valid_from,
            valid_to: effective_valid_to,
            attributes: attributes,
            current_time: current_time
          )

          # 4. CLOSE all affected records FIRST (critical ordering!)
          records_to_close.each do |record|
            record.update_transaction_to(current_time)
          end

          # 5. Insert all new timeline records
          new_timeline.each do |record|
            record.save_without_bitemporal_callbacks!(validate: false)
          end

          # 6. Validate the new timeline (post-hoc)
          validate_cascade_correction_timeline!

          # 7. Update self to point to the "current" record in the new timeline
          current_record = new_timeline.find { |r|
            r[valid_from_key] <= Time.current && r[valid_to_key] > Time.current
          } || new_timeline.last

          @_swapped_id = current_record.swapped_id
          self[valid_from_key] = current_record[valid_from_key]
          self[valid_to_key] = current_record[valid_to_key]
          self.transaction_from = current_record.transaction_from
          self.transaction_to = current_record.transaction_to

          true
        end
      end

      # Shift Genesis: Main implementation
      def _shift_genesis_record(new_valid_from:)
        current_time = Time.current

        ActiveRecord::Base.transaction(requires_new: true) do
          # 1. Lock all records for this entity
          self.class.where(bitemporal_id: bitemporal_id).lock!.pluck(:id)

          # 2. Fetch all current-knowledge segments
          segments = find_all_current_knowledge_segments

          # 3. Guard: entity must exist
          if segments.empty?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
              "(no current-knowledge records)",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          genesis = segments.first

          # 4. No-op: same date
          return true if new_valid_from == genesis[valid_from_key]

          # 5. Guard: forward shift must not erase all segments
          if new_valid_from >= segments.last[valid_to_key]
            raise ArgumentError,
              "shift_genesis would erase all segments: new_valid_from (#{new_valid_from}) " \
              ">= last segment valid_to (#{segments.last[valid_to_key]})"
          end

          # 6. Build records to close and new records
          records_to_close, new_records = if new_valid_from < genesis[valid_from_key]
            build_genesis_backward_shift(genesis, new_valid_from, current_time)
          else
            build_genesis_forward_shift(segments, new_valid_from, current_time)
          end

          # 7. CLOSE old records FIRST (critical ordering)
          records_to_close.each { |r| r.update_transaction_to(current_time) }

          # 8. Insert new records
          new_records.each { |r| r.save_without_bitemporal_callbacks!(validate: false) }

          # 9. Validate post-hoc (reuse existing)
          validate_cascade_correction_timeline!

          # 10. Update self to point at the currently-valid record
          all_current = find_all_current_knowledge_segments
          current_record = all_current.find { |r|
            r[valid_from_key] <= Time.current && r[valid_to_key] > Time.current
          } || all_current.last

          @_swapped_id = current_record.swapped_id
          self[valid_from_key] = current_record[valid_from_key]
          self[valid_to_key] = current_record[valid_to_key]
          self.transaction_from = current_record.transaction_from
          self.transaction_to = current_record.transaction_to

          true
        end
      end

      def find_all_current_knowledge_segments
        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .order(valid_from_key => :asc)
          .to_a
          .each { |record|
            record.id = record.swapped_id
            record.clear_changes_information
          }
      end

      def build_genesis_backward_shift(genesis, new_valid_from, current_time)
        new_genesis = genesis.dup
        new_genesis.id = nil
        new_genesis[valid_from_key] = new_valid_from
        new_genesis.transaction_from = current_time
        new_genesis.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO

        [[genesis], [new_genesis]]
      end

      def build_genesis_forward_shift(segments, new_valid_from, current_time)
        records_to_close = []
        new_records = []

        segments.each do |segment|
          if segment[valid_to_key] <= new_valid_from
            # Entirely before — close, no replacement
            records_to_close << segment

          elsif segment[valid_from_key] < new_valid_from
            # Spans the boundary — close + trimmed replacement
            records_to_close << segment

            trimmed = segment.dup
            trimmed.id = nil
            trimmed[valid_from_key] = new_valid_from
            trimmed.transaction_from = current_time
            trimmed.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
            new_records << trimmed

          else
            # valid_from >= new_valid_from — untouched, stop
            break
          end
        end

        [records_to_close, new_records]
      end

      def find_affected_records_for_correction(correction_valid_from)
        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .where("#{valid_to_key} > ?", correction_valid_from)
          .order(valid_from_key => :asc)
          .to_a
          .each { |record|
            record.id = record.swapped_id
            record.clear_changes_information
          }
      end

      def determine_correction_end(correction_valid_from, affected_records)
        # Find the record that contains valid_from
        containing_record = affected_records.find { |r|
          r[valid_from_key] <= correction_valid_from && r[valid_to_key] > correction_valid_from
        }

        if containing_record
          # Correction ends at this record's valid_to (next change point)
          containing_record[valid_to_key]
        else
          # valid_from is in a gap or before all records - use infinity
          ActiveRecord::Bitemporal::DEFAULT_VALID_TO
        end
      end

      def validate_cascade_correction_timeline!
        # Check for overlapping valid times at current transaction time
        records = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .order(valid_from_key => :asc)
          .to_a

        records.each_cons(2) do |r1, r2|
          if r1[valid_to_key] > r2[valid_from_key]
            message = "Overlapping valid periods detected: " \
                      "#{r1[valid_from_key]}-#{r1[valid_to_key]} overlaps with " \
                      "#{r2[valid_from_key]}-#{r2[valid_to_key]}"
            raise ActiveRecord::RecordInvalid.new(self), message
          end
        end
      end

      def bitemporal_build_cascade_correction_records(affected_records:, valid_from:, valid_to:, attributes:, current_time:)
        records_to_close = affected_records.dup
        new_timeline = []

        # Sort by valid_from to process in order
        sorted_records = affected_records.sort_by { |r| r[valid_from_key] }

        # 1. BEFORE: If first affected record starts before valid_from, create trimmed version
        first_record = sorted_records.first
        if first_record && first_record[valid_from_key] < valid_from
          before_record = first_record.dup
          before_record.id = nil
          before_record[valid_to_key] = valid_from
          before_record.transaction_from = current_time
          before_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
          new_timeline << before_record
        end

        # 2. CORRECTION: Create the corrected record with new attributes
        # Inherit from the record that contains valid_from (not from self)
        containing_record = sorted_records.find { |r|
          r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
        }
        correction_record = containing_record.dup
        correction_record.id = nil
        correction_record.assign_attributes(attributes)
        correction_record[valid_from_key] = valid_from
        correction_record[valid_to_key] = valid_to
        correction_record.transaction_from = current_time
        correction_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
        new_timeline << correction_record

        # 3. AFTER: Cascade - preserve records that extend past valid_to
        if valid_to < ActiveRecord::Bitemporal::DEFAULT_VALID_TO
          sorted_records.each do |record|
            next unless record[valid_to_key] > valid_to

            after_record = record.dup
            after_record.id = nil
            after_record.transaction_from = current_time
            after_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO

            if record[valid_from_key] < valid_to
              # Partially overlapped - trim start to valid_to (CASCADE!)
              after_record[valid_from_key] = valid_to
            end
            # else: Fully after - preserve as-is (valid_from unchanged)

            new_timeline << after_record
          end
        end

        [records_to_close, new_timeline.sort_by { |r| r[valid_from_key] }]
      end

      def bitemporal_assign_initialize_value(valid_datetime:, current_time: Time.current)
        # 自身の `valid_from` を設定
        self[valid_from_key] = valid_datetime || current_time if self[valid_from_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_FROM

        self.transaction_from = current_time if self.transaction_from == ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_FROM

         # Assign only if defined created_at and deleted_at
        if has_column?(:created_at)
          self.transaction_from = self.created_at if changes.key?("created_at")
          self.created_at = self.transaction_from
        end
        if has_column?(:deleted_at)
          self.transaction_to = self.deleted_at if changes.key?("deleted_at")
          self.deleted_at = self.transaction_to == ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO ? nil : self.transaction_to
        end
      end

      def bitemporal_build_update_records(valid_datetime:, current_time: Time.current, force_update: false)
        target_datetime = valid_datetime || current_time
        # NOTE: force_update の場合は自身のレコードを取得するような時間を指定しておく
        target_datetime = attribute_changed?(valid_from_key) ? attribute_was(valid_from_key) : self[valid_from_key] if force_update

        # 対象基準日において有効なレコード
        # NOTE: 論理削除対象
        current_valid_record = self.class.find_at_time(target_datetime, self.id)&.tap { |record|
          # 元々の id を詰めておく
          record.id = record.swapped_id
          record.clear_changes_information
        }

        # 履歴データとして保存する新しいインスタンス
        # NOTE: 以前の履歴データ(現時点で有効なレコードを元にする)
        before_instance = current_valid_record.dup
        # NOTE: 以降の履歴データ(自身のインスタンスを元にする)
        after_instance = build_new_instance

        # force_update の場合は既存のレコードを論理削除した上で新しいレコードを生成する
        if current_valid_record.present? && force_update
          # 有効なレコードは論理削除する
          current_valid_record.assign_transaction_to(current_time)
          # 以前の履歴データは valid_from/to を更新しないため、破棄する
          before_instance = nil
          # 以降の履歴データはそのまま保存
          after_instance.transaction_from = current_time

        # 有効なレコードがある場合
        elsif current_valid_record.present?
          # 有効なレコードは論理削除する
          current_valid_record.assign_transaction_to(current_time)

          # 以前の履歴データは valid_to を詰めて保存
          before_instance[valid_to_key] = target_datetime
          if before_instance.valid_from_cannot_be_greater_equal_than_valid_to
            message = "#{valid_from_key} #{before_instance[valid_from_key]} can't be " \
                      "greater than or equal to #{valid_to_key} #{before_instance[valid_to_key]} " \
                      "for #{self.class} with bitemporal_id=#{bitemporal_id}"
            raise ValidDatetimeRangeError.new(message)
          end
          before_instance.transaction_from = current_time

          # 以降の履歴データは valid_from と valid_to を調整して保存する
          after_instance[valid_from_key] = target_datetime
          after_instance[valid_to_key] = current_valid_record[valid_to_key]
          if after_instance.valid_from_cannot_be_greater_equal_than_valid_to
            message = "#{valid_from_key} #{after_instance[valid_from_key]} can't be " \
                      "greater than or equal to #{valid_to_key} #{after_instance[valid_to_key]} " \
                      "for #{self.class} with bitemporal_id=#{bitemporal_id}"
            raise ValidDatetimeRangeError.new(message)
          end
          after_instance.transaction_from = current_time

        # 有効なレコードがない場合
        else
          # 一番近い未来にある Instance を取ってきて、その valid_from を valid_to に入れる
          nearest_instance = self.class.where(bitemporal_id: bitemporal_id).ignore_valid_datetime.valid_from_gt(target_datetime).order(valid_from_key => :asc).first
          if nearest_instance.nil?
            message = "Update failed: Couldn't find #{self.class} with 'bitemporal_id'=#{self.bitemporal_id} and '#{valid_from_key}' > #{target_datetime}"
            raise ActiveRecord::RecordNotFound.new(message, self.class, "bitemporal_id", self.bitemporal_id)
          end

          # 有効なレコードは存在しない
          current_valid_record = nil

          # 以前の履歴データは有効なレコードを基準に生成するため、存在しない
          before_instance = nil

          # 以降の履歴データは valid_from と valid_to を調整して保存する
          after_instance[valid_from_key] = target_datetime
          after_instance[valid_to_key] = nearest_instance[valid_from_key]
          after_instance.transaction_from = current_time
        end

        [current_valid_record, before_instance, after_instance]
      end
    end

    module Uniqueness
      require_relative "./scope.rb"
      using ::ActiveRecord::Bitemporal::Scope::ActiveRecordRelationScope

      private

      def scope_relation(record, relation)
        finder_class = find_finder_class_for(record)
        return super unless finder_class.bi_temporal_model?

        relation = super(record, relation)

        target_datetime = record.valid_datetime || Time.current

        valid_from = record[record.valid_from_key].yield_self { |valid_from|
          # NOTE: valid_from が初期値の場合は現在の時間を基準としてバリデーションする
          # valid_from が初期値の場合は Persistence#_create_record に Time.current が割り当てられる為
          # バリデーション時と生成時で若干時間がずれてしまうことには考慮する
          if valid_from == ActiveRecord::Bitemporal::DEFAULT_VALID_FROM
            target_datetime
          # NOTE: 新規作成時以外では target_datetime の値を基準としてバリデーションする
          # 更新時にバリデーションする場合、valid_from の時間ではなくて target_datetime の時間を基準としているため
          # valid_from を基準としてしまうと整合性が取れなくなってしまう
          elsif !record.new_record?
            target_datetime
          else
            valid_from
          end
        }

        # MEMO: `force_update` does not refer to `valid_datetime`
        valid_from = record[record.valid_from_key] if record.force_update?

        valid_to = record[record.valid_to_key].yield_self { |valid_to|
          # NOTE: `cover?` may give incorrect results, when the time zone is not UTC and `valid_from` is date type
          #   Therefore, cast to type of `valid_from`
          record_valid_time = finder_class.type_for_attribute(record.valid_from_key).cast(record.valid_datetime)
          # レコードを更新する時に valid_datetime が valid_from ~ valid_to の範囲外だった場合、
          #   一番近い未来の履歴レコードを参照して更新する
          # という仕様があるため、それを考慮して valid_to を設定する
          if (record_valid_time && (record[record.valid_from_key]...record[record.valid_to_key]).cover?(record_valid_time)) == false && (record.persisted?)
            finder_class.ignore_valid_datetime.where(bitemporal_id: record.bitemporal_id).valid_from_gteq(target_datetime).order(record.valid_from_key => :asc).first[record.valid_from_key]
          else
            valid_to
          end
        }

        valid_at_scope = finder_class.unscoped.ignore_valid_datetime
            .valid_from_lt(valid_to).valid_to_gt(valid_from)
            .yield_self { |scope|
              # MEMO: #dup などでコピーした場合、id は存在しないが swapped_id のみ存在するケースがあるので
              # id と swapped_id の両方が存在する場合のみクエリを追加する
              record.id && record.swapped_id ? scope.where.not(id: record.swapped_id) : scope
            }

        # MEMO: Must refer Time.current, when not new record
        #       Because you don't want transaction_from to be rewritten
        transaction_from = if record.transaction_from == ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_FROM
                             Time.current
                           elsif !record.new_record?
                             Time.current
                           else
                             record.transaction_from
                           end
        transaction_to = record.transaction_to || ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
        transaction_at_scope = finder_class.unscoped
          .transaction_to_gt(transaction_from)
          .transaction_from_lt(transaction_to)

        relation.merge(valid_at_scope.with_valid_datetime).merge(transaction_at_scope.with_transaction_datetime)
      end
    end
  end
end

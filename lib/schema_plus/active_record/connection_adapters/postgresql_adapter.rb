module SchemaPlus
  module ActiveRecord
    module ConnectionAdapters
      # PostgreSQL-specific extensions to column definitions in a table.
      module PostgreSQLColumn
        def initialize(name, default, cast_type, sql_type = nil, null = true, default_function = nil)
          super(name, default, cast_type, sql_type, null)
          @default_function = @default_expr = default_function
        end
      end

      # The Postgresql adapter implements the SchemaPlus extensions and
      # enhancements
      module PostgresqlAdapter

        def self.included(base) #:nodoc:
          base.class_eval do
            alias_method_chain :rename_table, :schema_plus
            alias_method_chain :exec_cache, :schema_plus
          end
          ::ActiveRecord::ConnectionAdapters::PostgreSQLColumn.send(:include, PostgreSQLColumn) unless ::ActiveRecord::ConnectionAdapters::PostgreSQLColumn.include?(PostgreSQLColumn)
        end

        # SchemaPlus provides the following extra options for PostgreSQL
        # indexes:
        # * +:conditions+ - SQL conditions for the WHERE clause of the index
        # * +:expression+ - SQL expression to index.  column_name can be nil or ommitted, in which case :name must be provided
        # * +:kind+ - index method for Postgresql to use
        # * +:operator_class+ - an operator class name or a hash mapping column name to operator class name
        # * +:case_sensitive - setting to +false+ is a shorthand for :expression => 'LOWER(column_name)'
        #
        # The <tt>:case_sensitive => false</tt> option ties in with Rails built-in support for case-insensitive searching:
        #    validates_uniqueness_of :name, :case_sensitive => false
        #
        # Since since <tt>:case_sensitive => false</tt> is implemented by
        # using <tt>:expression</tt>, this raises an ArgumentError if both
        # are specified simultaneously.
        #
        def add_index(table_name, column_name, options = {})
          options = {} if options.nil?  # some callers explicitly pass options=nil
          column_name, options = [], column_name if column_name.is_a?(Hash)
          column_names = Array(column_name).compact
          column_names += Array(options[:with] || [])
          if column_names.empty?
            raise ArgumentError, "No columns and :expression missing from options - cannot create index" unless options[:expression]
            raise ArgumentError, "Index name not given. Pass :name option" unless options[:name]
          end

          index_type = options[:unique] ? "UNIQUE" : ""
          index_name = options[:name] || index_name(table_name, column_names)
          conditions = options[:conditions]
          kind       = options[:kind]
          operator_classes = options[:operator_class]
          if operator_classes and not operator_classes.is_a? Hash
            operator_classes = Hash[column_names.map {|name| [name, operator_classes]}]
          end

          if expression = options[:expression] then
            raise ArgumentError, "Cannot specify :case_sensitive => false with an expression.  Use LOWER(column_name)" if options[:case_sensitive] == false
            # Wrap expression in parentheses if necessary
            expression = "(#{expression})" if expression !~ /(using|with|tablespace|where)/i
            expression = "USING #{kind} #{expression}" if kind
            expression = "#{expression} WHERE #{conditions}" if conditions

            sql = "CREATE #{index_type} INDEX #{quote_column_name(index_name)} ON #{quote_table_name(table_name)} #{expression}"
          else
            option_strings = Hash[column_names.map {|name| [name, '']}]
            (operator_classes||{}).each do |column, opclass|
              option_strings[column] += " #{opclass}" if opclass
            end
            option_strings = add_index_sort_order(option_strings, column_names, options)

            if options[:case_sensitive] == false
              caseable_columns = columns(table_name).select { |col| [:string, :text].include?(col.type) }.map(&:name)
              quoted_column_names = column_names.map do |col_name|
                (caseable_columns.include?(col_name.to_s) ? "LOWER(#{quote_column_name(col_name)})" : quote_column_name(col_name)) + option_strings[col_name]
              end
            else
              quoted_column_names = column_names.map { |col_name| quote_column_name(col_name) + option_strings[col_name] }
            end

            expression = "(#{quoted_column_names.join(', ')})"
            expression = "USING #{kind} #{expression}" if kind

            sql = "CREATE #{index_type} INDEX #{quote_column_name(index_name)} ON #{quote_table_name(table_name)} #{expression}"
            sql += " WHERE (#{ ::ActiveRecord::Base.send(:sanitize_sql, conditions, quote_table_name(table_name)) })" if conditions
          end
          execute sql
        rescue => e
          SchemaStatements.add_index_exception_handler(self, table_name, column_names, options, e)
        end

        def supports_partial_indexes? #:nodoc:
          true
        end

        # This method entirely duplicated from AR's postgresql_adapter.c,
        # but includes the extra bit to determine the column name for a
        # case-insensitive index.  (Haven't come up with any clever way to
        # only code up the case-insensitive column name bit here and
        # otherwise use the existing method.)
        def indexes(table_name, name = nil) #:nodoc:
          result = query(<<-SQL, name)

           SELECT distinct i.relname, d.indisunique, d.indkey, pg_get_indexdef(d.indexrelid), t.oid,
                  m.amname, pg_get_expr(d.indpred, t.oid) as conditions, pg_get_expr(d.indexprs, t.oid) as expression,
                  d.indclass
           FROM pg_class t
           INNER JOIN pg_index d ON t.oid = d.indrelid
           INNER JOIN pg_class i ON d.indexrelid = i.oid
           INNER JOIN pg_am m ON i.relam = m.oid
           WHERE i.relkind = 'i'
             AND d.indisprimary = 'f'
             AND t.relname = '#{table_name_without_namespace(table_name)}'
             AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname = #{namespace_sql(table_name)} )
          ORDER BY i.relname
          SQL

          result.map do |(index_name, is_unique, indkey, inddef, oid, kind, conditions, expression, indclass)|
            unique = (is_unique == 't' || is_unique == true) # The test against true is for JDBC which is returning a boolean and not a String.
            index_keys = indkey.split(" ")
            opclasses = indclass.split(" ")

            rows = query(<<-SQL, "Columns for index #{index_name} on #{table_name}")
              SELECT CAST(a.attnum as VARCHAR), a.attname, t.typname
              FROM pg_attribute a
              INNER JOIN pg_type t ON a.atttypid = t.oid
              WHERE a.attrelid = #{oid}
            SQL
            columns = {}
            types = {}
            rows.each do |num, name, type|
              columns[num] = name
              types[name] = type
            end

            column_names = columns.values_at(*index_keys).compact
            case_sensitive = true

            # extract column names from the expression, for a
            # case-insensitive index.
            # only applies to character, character varying, and text
            if expression
              rexp_lower = %r{\blower\(\(?([^)]+)(\)::text)?\)}
              if expression.match /\A#{rexp_lower}(?:, #{rexp_lower})*\z/
                case_insensitive_columns = expression.scan(rexp_lower).map(&:first).select{|column| %W[char varchar text].include? types[column]}
                if case_insensitive_columns.any?
                  case_sensitive = false
                  column_names = index_keys.map { |index_key|
                    index_key == '0' ? case_insensitive_columns.shift : columns[index_key]
                  }.compact
                end
              end
            end

            opclass_name  = {}
            rows = query(<<-SQL, "Op classes for index #{index_name} on #{table_name}")
              SELECT oid, opcname FROM pg_opclass
              WHERE (NOT opcdefault) AND oid IN (#{opclasses.join(',')})
            SQL
            rows.each do |oid, opcname|
              opclass_name[oid.to_s] = opcname
            end
            operator_classes = {}
            index_keys.zip(opclasses).each do |index_key, opclass|
              operator_classes[columns[index_key]] = opclass_name[opclass]
            end
            operator_classes.delete_if{|k,v| v.nil?}

            # add info on sort order for columns (only desc order is explicitly specified, asc is the default)
            desc_order_columns = inddef.scan(/(\w+) DESC/).flatten
            orders = desc_order_columns.any? ? Hash[column_names.map {|column| [column, desc_order_columns.include?(column) ? :desc : :asc]}] : {}

            ::ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, column_names,
                                                                    :name => index_name,
                                                                    :unique => unique,
                                                                    :orders => orders,
                                                                    :conditions => conditions,
                                                                    :case_sensitive => case_sensitive,
                                                                    :kind => kind.downcase == "btree" ? nil : kind,
                                                                    :operator_classes => operator_classes,
                                                                    :expression => expression)
          end
        end

        def rename_table_with_schema_plus(oldname, newname) #:nodoc:
          rename_table_without_schema_plus(oldname, newname)
          rename_foreign_keys(oldname, newname)
        end

        # Prepass to replace each ActiveRecord::DB_DEFAULT with a literal
        # DEFAULT in the sql string.  (The underlying pg gem provides no
        # way to bind a value that will replace $n with DEFAULT)
        def exec_cache_with_schema_plus(sql, *args)
          name_passed = (2 == args.size)
          binds, name = args.reverse

          if binds.any?{ |col, val| val.equal? ::ActiveRecord::DB_DEFAULT}
            j = 0
            binds.each_with_index do |(col, val), i|
            if val.equal? ::ActiveRecord::DB_DEFAULT
              sql = sql.sub(/\$#{i+1}/, 'DEFAULT')
            else
              sql = sql.sub(/\$#{i+1}/, "$#{j+1}") if i != j
              j += 1
            end
            end
            binds = binds.reject{|col, val| val.equal? ::ActiveRecord::DB_DEFAULT}
          end

          args = name_passed ? [name, binds] : [binds]
          exec_cache_without_schema_plus(sql, *args)
        end

        def foreign_keys(table_name, name = nil) #:nodoc:
          load_foreign_keys(<<-SQL, name)
        SELECT f.conname, pg_get_constraintdef(f.oid), t.relname
          FROM pg_class t, pg_constraint f
         WHERE f.conrelid = t.oid
           AND f.contype = 'f'
           AND t.relname = '#{table_name_without_namespace(table_name)}'
           AND t.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname = #{namespace_sql(table_name)} )
          SQL
        end

        def reverse_foreign_keys(table_name, name = nil) #:nodoc:
          load_foreign_keys(<<-SQL, name)
        SELECT f.conname, pg_get_constraintdef(f.oid), t2.relname
          FROM pg_class t, pg_class t2, pg_constraint f
         WHERE f.confrelid = t.oid
           AND f.conrelid = t2.oid
           AND f.contype = 'f'
           AND t.relname = '#{table_name_without_namespace(table_name)}'
           AND t.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname = #{namespace_sql(table_name)} )
          SQL
        end

        def views(name = nil) #:nodoc:
          sql = <<-SQL
            SELECT viewname
              FROM pg_views
            WHERE schemaname = ANY (current_schemas(false))
            AND viewname NOT LIKE 'pg\_%'
          SQL
          sql += " AND schemaname != 'postgis'" if adapter_name == 'PostGIS'
          query(sql, name).map { |row| row[0] }
        end

        def view_definition(view_name, name = nil) #:nodoc:
          result = query(<<-SQL, name)
        SELECT pg_get_viewdef(oid)
          FROM pg_class
         WHERE relkind = 'v'
           AND relname = '#{view_name}'
          SQL
          row = result.first
          row.first.chomp(';') unless row.nil?
        end

        def enums #:nodoc:
          result = query(<<-SQL)
            SELECT
              N.nspname AS schema_name,
              T.typname AS enum_name,
              E.enumlabel AS enum_label,
              E.enumsortorder AS enum_sort_order
              --array_agg(E.enumlabel ORDER BY enumsortorder) AS labels
            FROM pg_type T
            JOIN pg_enum E ON E.enumtypid = T.oid
            JOIN pg_namespace N ON N.oid = T.typnamespace
            ORDER BY 1, 2, 4
          SQL

          result.reduce([]) do |res, row|
            last = res.last
            if last && last[0] == row[0] && last[1] == row[1]
              last[2] << row[2]
            else
              res << (row[0..1] << [row[2]])
            end
            res
          end
        end

        def create_enum(name, *values)
          options = values.extract_options!
          list = values.map { |value| escape_enum_value(value) }
          execute "CREATE TYPE #{enum_name(name, options[:schema])} AS ENUM (#{list.join(',')})"
        end

        def alter_enum(name, value, options = {})
          opts = case
                 when options[:before] then "BEFORE #{escape_enum_value(options[:before])}"
                 when options[:after] then "AFTER #{escape_enum_value(options[:after])}"
                 else
                   ''
                 end
          execute "ALTER TYPE #{enum_name(name, options[:schema])} ADD VALUE #{escape_enum_value(value)} #{opts}"
        end

        def drop_enum(name, options = {})
          execute "DROP TYPE #{enum_name(name, options[:schema])}"
        end

        # pg gem defines a drop_table with fewer options than our Abstract
        # one, so use the abstract one instead
        def drop_table(name, options={})
          SchemaPlus::ActiveRecord::ConnectionAdapters::AbstractAdapter.instance_method(:drop_table).bind(self).call(name, options)
        end

        private

        def enum_name(name, schema)
          [schema || 'public', name].map { |s|
            %Q{"#{s}"}
          }.join('.')
        end

        def escape_enum_value(value)
          escaped_value = value.sub("'", "''")
          "'#{escaped_value}'"
        end

        def namespace_sql(table_name)
          (table_name.to_s =~ /(.*)[.]/) ?  "'#{$1}'" : "ANY (current_schemas(false))"
        end

        def table_name_without_namespace(table_name)
          table_name.to_s.sub /.*[.]/, ''
        end

        def load_foreign_keys(sql, name = nil) #:nodoc:
          foreign_keys = []

          query(sql, name).each do |row|
            if row[1] =~ /^FOREIGN KEY \((.+?)\) REFERENCES (.+?)\((.+?)\)( ON UPDATE (.+?))?( ON DELETE (.+?))?( (DEFERRABLE|NOT DEFERRABLE)( (INITIALLY DEFERRED|INITIALLY IMMEDIATE))?)?$/
              name = row[0]
              from_table_name = row[2]
              column_names = $1
              references_table_name = $2
              references_column_names = $3
              on_update = $5
              on_delete = $7
              deferrable = $9 == "DEFERRABLE"
              deferrable = :initially_deferred if ($11 == "INITIALLY DEFERRED" )
              on_update = on_update ? on_update.downcase.gsub(' ', '_').to_sym : :no_action
              on_delete = on_delete ? on_delete.downcase.gsub(' ', '_').to_sym : :no_action

              options = { :name => name,
                          :on_delete => on_delete,
                          :on_update => on_update,
                          :column_names => column_names.split(', '),
                          :references_column_names => references_column_names.split(', '),
                          :deferrable => deferrable }

              foreign_keys << ForeignKeyDefinition.new(from_table_name,
                                                       references_table_name.sub(/^"(.*)"$/, '\1'),
                                                       options)
            end
          end

          foreign_keys
        end

        module AddColumnOptions
          def default_expr_valid?(expr)
            true # arbitrary sql is okay in PostgreSQL
          end

          def sql_for_function(function)
            case function
              when :now
                "NOW()"
            end
          end
        end
      end
    end
  end
end

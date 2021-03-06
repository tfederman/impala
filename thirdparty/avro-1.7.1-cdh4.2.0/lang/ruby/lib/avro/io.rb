# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Avro
  module IO
    # Raised when datum is not an example of schema
    class AvroTypeError < AvroError
      def initialize(expected_schema, datum)
        super("The datum #{datum.inspect} is not an example of schema #{expected_schema}")
      end
    end

    # Raised when writer's and reader's schema do not match
    class SchemaMatchException < AvroError
      def initialize(writers_schema, readers_schema)
        super("Writer's schema #{writers_schema} and Reader's schema " +
              "#{readers_schema} do not match.")
      end
    end

    # FIXME(jmhodges) move validate to this module?

    class BinaryDecoder
      # Read leaf values

      # reader is an object on which we can call read, seek and tell.
      attr_reader :reader
      def initialize(reader)
        @reader = reader
      end

      def byte!
        @reader.read(1).unpack('C').first
      end
      
      def read_null
        # null is written as zero byte's
        nil
      end

      def read_boolean
        byte! == 1
      end

      def read_int; read_long; end

      def read_long
        # int and long values are written using variable-length,
        # zig-zag coding.
        b = byte!
        n = b & 0x7F
        shift = 7
        while (b & 0x80) != 0
          b = byte!
          n |= (b & 0x7F) << shift
          shift += 7
        end
        (n >> 1) ^ -(n & 1)
      end

      def read_float
        # A float is written as 4 bytes.
        # The float is converted into a 32-bit integer using a method
        # equivalent to Java's floatToIntBits and then encoded in
        # little-endian format.
        @reader.read(4).unpack('e')[0]
      end

      def read_double
        #  A double is written as 8 bytes.
        # The double is converted into a 64-bit integer using a method
        # equivalent to Java's doubleToLongBits and then encoded in
        # little-endian format.
        @reader.read(8).unpack('E')[0]
      end

      def read_bytes
        # Bytes are encoded as a long followed by that many bytes of
        # data.
        read(read_long)
      end

      def read_string
        # A string is encoded as a long followed by that many bytes of
        # UTF-8 encoded character data.
        # FIXME utf-8 encode this in 1.9
        read_bytes
      end

      def read(len)
        # Read n bytes
        @reader.read(len)
      end

      def skip_null
        nil
      end

      def skip_boolean
        skip(1)
      end

      def skip_int
        skip_long
      end

      def skip_long
        b = byte!
        while (b & 0x80) != 0
          b = byte!
        end
      end

      def skip_float
        skip(4)
      end

      def skip_double
        skip(8)
      end

      def skip_bytes
        skip(read_long)
      end

      def skip_string
        skip_bytes
      end

      def skip(n)
        reader.seek(reader.tell() + n)
      end
    end

    # Write leaf values
    class BinaryEncoder
      attr_reader :writer

      def initialize(writer)
        @writer = writer
      end

      # null is written as zero bytes
      def write_null(datum)
        nil
      end

      # a boolean is written as a single byte 
      # whose value is either 0 (false) or 1 (true).
      def write_boolean(datum)
        on_disk = datum ? 1.chr : 0.chr
        writer.write(on_disk)
      end

      # int and long values are written using variable-length,
      # zig-zag coding.
      def write_int(n)
        write_long(n)
      end

      # int and long values are written using variable-length,
      # zig-zag coding.
      def write_long(n)
        foo = n
        n = (n << 1) ^ (n >> 63)
        while (n & ~0x7F) != 0
          @writer.write(((n & 0x7f) | 0x80).chr)
          n >>= 7
        end
        @writer.write(n.chr)
      end

      # A float is written as 4 bytes.
      # The float is converted into a 32-bit integer using a method
      # equivalent to Java's floatToIntBits and then encoded in
      # little-endian format.
      def write_float(datum)
        @writer.write([datum].pack('e'))
      end

      # A double is written as 8 bytes.
      # The double is converted into a 64-bit integer using a method
      # equivalent to Java's doubleToLongBits and then encoded in
      # little-endian format.
      def write_double(datum)
        @writer.write([datum].pack('E'))
      end

      # Bytes are encoded as a long followed by that many bytes of data.
      def write_bytes(datum)
        write_long(datum.size)
        @writer.write(datum)
      end

      # A string is encoded as a long followed by that many bytes of
      # UTF-8 encoded character data
      def write_string(datum)
        # FIXME utf-8 encode this in 1.9
        write_bytes(datum)
      end

      # Write an arbritary datum.
      def write(datum)
        writer.write(datum)
      end
    end

    class DatumReader
      def self.check_props(schema_one, schema_two, prop_list)
        prop_list.all? do |prop|
          schema_one.send(prop) == schema_two.send(prop)
        end
      end

      def self.match_schemas(writers_schema, readers_schema)
        w_type = writers_schema.type
        r_type = readers_schema.type

        # This conditional is begging for some OO love.
        if w_type == 'union' || r_type == 'union'
          return true
        end

        if w_type == r_type
          if Schema::PRIMITIVE_TYPES.include?(w_type) &&
              Schema::PRIMITIVE_TYPES.include?(r_type)
            return true
          end

          case r_type
          when 'record'
            return check_props(writers_schema, readers_schema, [:fullname])
          when 'error'
            return check_props(writers_scheam, readers_schema, [:fullname])
          when 'request'
            return true
          when 'fixed'
            return check_props(writers_schema, readers_schema, [:fullname, :size])
          when 'enum'
            return check_props(writers_schema, readers_schema, [:fullname])
          when 'map'
            return check_props(writers_schema.values, readers_schema.values, [:type])
          when 'array'
            return check_props(writers_schema.items, readers_schema.items, [:type])
          end
        end

        # Handle schema promotion
        if w_type == 'int' && ['long', 'float', 'double'].include?(r_type)
          return true
        elsif w_type == 'long' && ['float', 'double'].include?(r_type)
          return true
        elsif w_type == 'float' && r_type == 'double'
          return true
        end

        return false
      end

      attr_accessor :writers_schema, :readers_schema

      def initialize(writers_schema=nil, readers_schema=nil)
        @writers_schema = writers_schema
        @readers_schema = readers_schema
      end

      def read(decoder)
        self.readers_schema = writers_schema unless readers_schema
        read_data(writers_schema, readers_schema, decoder)
      end

      def read_data(writers_schema, readers_schema, decoder)
        # schema matching
        unless self.class.match_schemas(writers_schema, readers_schema)
          raise SchemaMatchException.new(writers_schema, readers_schema)
        end

        # schema resolution: reader's schema is a union, writer's
        # schema is not
        if writers_schema.type != 'union' && readers_schema.type == 'union'
          rs = readers_schema.schemas.find{|s|
            self.class.match_schemas(writers_schema, s)
          }
          return read_data(writers_schema, rs, decoder) if rs
          raise SchemaMatchException.new(writers_schema, readers_schema)
        end

        # function dispatch for reading data based on type of writer's
        # schema
        case writers_schema.type
        when 'null';    decoder.read_null
        when 'boolean'; decoder.read_boolean
        when 'string';  decoder.read_string
        when 'int';     decoder.read_int
        when 'long';    decoder.read_long
        when 'float';   decoder.read_float
        when 'double';  decoder.read_double
        when 'bytes';   decoder.read_bytes
        when 'fixed';   read_fixed(writers_schema, readers_schema, decoder)
        when 'enum';    read_enum(writers_schema, readers_schema, decoder)
        when 'array';   read_array(writers_schema, readers_schema, decoder)
        when 'map';     read_map(writers_schema, readers_schema, decoder)
        when 'union';   read_union(writers_schema, readers_schema, decoder)
        when 'record', 'errors', 'request';  read_record(writers_schema, readers_schema, decoder)
        else
          raise AvroError, "Cannot read unknown schema type: #{writers_schema.type}"
        end
      end

      def read_fixed(writers_schema, readers_schema, decoder)
        decoder.read(writers_schema.size)
      end

      def read_enum(writers_schema, readers_schema, decoder)
        index_of_symbol = decoder.read_int
        read_symbol = writers_schema.symbols[index_of_symbol]

        # TODO(jmhodges): figure out what unset means for resolution
        # schema resolution
        unless readers_schema.symbols.include?(read_symbol)
          # 'unset' here
        end

        read_symbol
      end

      def read_array(writers_schema, readers_schema, decoder)
        read_items = []
        block_count = decoder.read_long
        while block_count != 0
          if block_count < 0
            block_count = -block_count
            block_size = decoder.read_long
          end
          block_count.times do
            read_items << read_data(writers_schema.items,
                                    readers_schema.items,
                                    decoder)
          end
          block_count = decoder.read_long
        end

        read_items
      end

      def read_map(writers_schema, readers_schema, decoder)
        read_items = {}
        block_count = decoder.read_long
        while block_count != 0
          if block_count < 0
            block_count = -block_count
            block_size = decoder.read_long
          end
          block_count.times do
            key = decoder.read_string
            read_items[key] = read_data(writers_schema.values,
                                        readers_schema.values,
                                        decoder)
          end
          block_count = decoder.read_long
        end

        read_items
      end

      def read_union(writers_schema, readers_schema, decoder)
        index_of_schema = decoder.read_long
        selected_writers_schema = writers_schema.schemas[index_of_schema]

        read_data(selected_writers_schema, readers_schema, decoder)
      end

      def read_record(writers_schema, readers_schema, decoder)
        readers_fields_hash = readers_schema.fields_hash
        read_record = {}
        writers_schema.fields.each do |field|
          if readers_field = readers_fields_hash[field.name]
            field_val = read_data(field.type, readers_field.type, decoder)
            read_record[field.name] = field_val
          else
            skip_data(field.type, decoder)
          end
        end

        # fill in the default values
        if readers_fields_hash.size > read_record.size
          writers_fields_hash = writers_schema.fields_hash
          readers_fields_hash.each do |field_name, field|
            unless writers_fields_hash.has_key? field_name
              if !field.default.nil?
                field_val = read_default_value(field.type, field.default)
                read_record[field.name] = field_val
              else
                # FIXME(jmhodges) another 'unset' here
              end
            end
          end
        end

        read_record
      end

      def read_default_value(field_schema, default_value)
        # Basically a JSON Decoder?
        case field_schema.type
        when 'null'
          return nil
        when 'boolean'
          return default_value
        when 'int', 'long'
          return Integer(default_value)
        when 'float', 'double'
          return Float(default_value)
        when 'enum', 'fixed', 'string', 'bytes'
          return default_value
        when 'array'
          read_array = []
          default_value.each do |json_val|
            item_val = read_default_value(field_schema.items, json_val)
            read_array << item_val
          end
          return read_array
        when 'map'
          read_map = {}
          default_value.each do |key, json_val|
            map_val = read_default_value(field_schema.values, json_val)
            read_map[key] = map_val
          end
          return read_map
        when 'union'
          return read_default_value(field_schema.schemas[0], default_value)
        when 'record'
          read_record = {}
          field_schema.fields.each do |field|
            json_val = default_value[field.name]
            json_val = field.default unless json_val
            field_val = read_default_value(field.type, json_val)
            read_record[field.name] = field_val
          end
          return read_record
        else
          fail_msg = "Unknown type: #{field_schema.type}"
          raise AvroError(fail_msg)
        end
      end

      def skip_data(writers_schema, decoder)
        case writers_schema.type
        when 'null'
          decoder.skip_null
        when 'boolean'
          decoder.skip_boolean
        when 'string'
          decoder.skip_string
        when 'int'
          decoder.skip_int
        when 'long'
          decoder.skip_long
        when 'float'
          decoder.skip_float
        when 'double'
          decoder.skip_double
        when 'bytes'
          decoder.skip_bytes
        when 'fixed'
          skip_fixed(writers_schema, decoder)
        when 'enum'
          skip_enum(writers_schema, decoder)
        when 'array'
          skip_array(writers_schema, decoder)
        when 'map'
          skip_map(writers_schema, decoder)
        when 'union'
          skip_union(writers_schema, decoder)
        when 'record', 'error', 'request'
          skip_record(writers_schema, decoder)
        else
          raise AvroError, "Unknown schema type: #{schm.type}"
        end
      end

      def skip_fixed(writers_schema, decoder)
        decoder.skip(writers_schema.size)
      end

      def skip_enum(writers_schema, decoder)
        decoder.skip_int
      end

      def skip_union(writers_schema, decoder)
        index = decoder.read_long
        skip_data(writers_schema.schemas[index], decoder)
      end

      def skip_array(writers_schema, decoder)
        skip_blocks(decoder) { skip_data(writers_schema.items, decoder) }
      end

      def skip_map(writers_schema, decoder)
        skip_blocks(decoder) {
          decoder.skip_string
          skip_data(writers_schema.values, decoder)
        }
      end

      def skip_record(writers_schema, decoder)
        writers_schema.fields.each{|f| skip_data(f.type, decoder) }
      end

      private
      def skip_blocks(decoder, &blk)
        block_count = decoder.read_long
        while block_count != 0
          if block_count < 0
            decoder.skip(decoder.read_long)
          else
            block_count.times &blk
          end
          block_count = decoder.read_long
        end
      end
    end # DatumReader

    # DatumWriter for generic ruby objects
    class DatumWriter
      attr_accessor :writers_schema
      def initialize(writers_schema=nil)
        @writers_schema = writers_schema
      end

      def write(datum, encoder)
        write_data(writers_schema, datum, encoder)
      end

      def write_data(writers_schema, datum, encoder)
        unless Schema.validate(writers_schema, datum)
          raise AvroTypeError.new(writers_schema, datum)
        end

        # function dispatch to write datum
        case writers_schema.type
        when 'null';    encoder.write_null(datum)
        when 'boolean'; encoder.write_boolean(datum)
        when 'string';  encoder.write_string(datum)
        when 'int';     encoder.write_int(datum)
        when 'long';    encoder.write_long(datum)
        when 'float';   encoder.write_float(datum)
        when 'double';  encoder.write_double(datum)
        when 'bytes';   encoder.write_bytes(datum)
        when 'fixed';   write_fixed(writers_schema, datum, encoder)
        when 'enum';    write_enum(writers_schema, datum, encoder)
        when 'array';   write_array(writers_schema, datum, encoder)
        when 'map';     write_map(writers_schema, datum, encoder)
        when 'union';   write_union(writers_schema, datum, encoder)
        when 'record', 'errors', 'request';  write_record(writers_schema, datum, encoder)
        else
          raise AvroError.new("Unknown type: #{writers_schema.type}")
        end
      end

      def write_fixed(writers_schema, datum, encoder)
        encoder.write(datum)
      end

      def write_enum(writers_schema, datum, encoder)
        index_of_datum = writers_schema.symbols.index(datum)
        encoder.write_int(index_of_datum)
      end

      def write_array(writers_schema, datum, encoder)
        if datum.size > 0
          encoder.write_long(datum.size)
          datum.each do |item|
            write_data(writers_schema.items, item, encoder)
          end
        end
        encoder.write_long(0)
      end

      def write_map(writers_schema, datum, encoder)
        if datum.size > 0
          encoder.write_long(datum.size)
          datum.each do |k,v|
            encoder.write_string(k)
            write_data(writers_schema.values, v, encoder)
          end
        end
        encoder.write_long(0)
      end

      def write_union(writers_schema, datum, encoder)
        index_of_schema = -1
        found = writers_schema.schemas.
          find{|e| index_of_schema += 1; found = Schema.validate(e, datum) }
        unless found  # Because find_index doesn't exist in 1.8.6
          raise AvroTypeError.new(writers_schema, datum)
        end
        encoder.write_long(index_of_schema)
        write_data(writers_schema.schemas[index_of_schema], datum, encoder)
      end

      def write_record(writers_schema, datum, encoder)
        writers_schema.fields.each do |field|
          write_data(field.type, datum[field.name], encoder)
        end
      end
    end # DatumWriter
  end
end

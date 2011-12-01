require 'bitcoin/script'

module Bitcoin
  module Protocol

    class Tx
      attr_reader :hash, :in, :out, :payload
      attr_accessor :ver, :lock_time

      def ==(other)
        @hash == other.hash
      end

      def binary_hash
        [@hash].pack("H*").reverse
      end

      def initialize(data)
        @ver, @lock_time = 1, 0

        parse_data(data) if data
      end

      def hash_from_payload(payload) # tx hash in hex from payload
        Digest::SHA256.digest(Digest::SHA256.digest( payload )).reverse.unpack("H*")[0]
      end
      alias generate_hash hash_from_payload

      def add_in(input); (@in ||= []) << input; end
      def add_out(output); (@out ||= []) << output; end

      def parse_data(data)
        @ver = data.unpack("I")[0]
        idx = 4
        in_size, tmp = Protocol.read_var_int(data[idx..-1])
        idx += data[idx..-1].bytesize-tmp.bytesize
        raise "unkown transaction version: #{@ver}" unless @ver == 1

        @in = (0...in_size).map{
          prev_out, prev_out_index = data[idx...idx+=36].unpack("a32I")
          script_sig_length, tmp = Protocol.read_var_int(data[idx..-1])
          idx += data[idx..-1].bytesize-tmp.bytesize
          script_sig = data[idx...idx+=script_sig_length]
          seq = data[idx...idx+=4]
          [ prev_out, prev_out_index, script_sig_length, script_sig, seq ]
        }

        out_size, tmp = Protocol.read_var_int(data[idx..-1])
        idx += data[idx..-1].bytesize-tmp.bytesize

        @out = (0...out_size).map{
          value = data[idx...idx+=8].unpack("Q")[0]
          pk_script_length, tmp = Protocol.read_var_int(data[idx..-1])
          idx += data[idx..-1].bytesize-tmp.bytesize
          pk_script = data[idx...idx+=pk_script_length]
          [ value, pk_script_length, pk_script ]
        }

        @lock_time = data[idx...idx+=4].unpack("I")[0]

        @payload = data[0...idx]
        @hash = hash_from_payload(@payload)

        if data[idx] == nil
          true          # reached the end.
        else
          data[idx..-1] # rest of buffer.
        end
      end

      def to_payload
        pin = @in.map{|i|
          buf =  [ i[0], i[1], i[2] ].pack("a32IC") # prev_out, prev_out_index, script_sig_length
          p ['var_int', i] if i[2] > 253            # TODO: var_int for script_sig_length
          buf << i[3] if i[2] > 0                   # script_sig
          buf << "\xff\xff\xff\xff"                 # sequence
        }.join

        pout = @out.map{|i|
          buf =  [ i[0], i[1] ].pack("QC")          # value, pk_script_length # TODO: var_int for pk_script_length
          buf << i[2] if i[1] > 0                   # pk_script
          buf
        }.join

        # TODO: use var_int for input/output size here.
        [@ver, @in.size, pin, @out.size, pout, @lock_time].pack("ICa#{pin.bytesize}Ca#{pout.bytesize}I")
      end


      def signature_hash_for_input(input_idx, outpoint_tx, script_pubkey=nil)
        # https://github.com/bitcoin/bitcoin/blob/e071a3f6c06f41068ad17134189a4ac3073ef76b/script.cpp#L834
        # http://code.google.com/p/bitcoinj/source/browse/trunk/src/com/google/bitcoin/core/Script.java#318

        pin  = @in.map.with_index{|i,idx|
          if idx == input_idx
            script_pubkey ||= outpoint_tx.out[ i[1] ][2]
            length = script_pubkey.bytesize
            [ i[0], i[1], length, script_pubkey, "\xff\xff\xff\xff" ].pack("a32ICa#{length}a4")
          else
            [ i[0], i[1], 0, "\xff\xff\xff\xff" ].pack("a32ICa4")
          end
        }.join
        pout = @out.map{|i| [ i[0], i[1], i[2] ].pack("QCa#{i[1]}") }.join

        hash_type = 1 # 1: ALL, 2: NONE, 3: SINGLE

        buf = [@ver, @in.size, pin, @out.size, pout, @lock_time].pack("ICa#{pin.bytesize}Ca#{pout.bytesize}I") +
              [hash_type].pack("I")
        Digest::SHA256.digest( Digest::SHA256.digest( buf ) )
      end

      def verify_input_signature(in_idx, outpoint_tx)
        outpoint_idx  = @in[in_idx][1]
        script_sig    = @in[in_idx][3]
        script_pubkey = outpoint_tx.out[outpoint_idx][2]
        script        = script_sig + script_pubkey

        Bitcoin::Script.new(script).run do |pubkey,sig,hash_type|
          # this IS the checksig callback, must return true/false
          #p ['checksig', pubkey, sig, hash_type]
          #hash = signature_hash_for_input(in_idx, outpoint_tx)
          hash = signature_hash_for_input(in_idx, nil, script_pubkey)
          Bitcoin.verify_signature( hash, sig, pubkey.unpack("H*")[0] )
        end
      end

      def to_hash
        h = {
          'hash' => @hash, 'ver' => @ver,
          'vin_sz' => @in.size, 'vout_sz' => @out.size,
          'lock_time' => @lock_time, 'size' => @payload.bytesize,
          'in' => @in.map{|i|{
            'prev_out'  => { 'hash' => hth(i[0]), 'n' => i[1] },
            'scriptSig' => Bitcoin::Script.new(i[3]).to_string
          }},
          'out' => @out.map{|i|{
            'value' => "%.8f" % (i[0] / 100000000.0),
            'scriptPubKey' => Bitcoin::Script.new(i[2]).to_string
          }}
        }
        if (i=@in[0]) && i[1] == 4294967295 # coinbase tx
          h['in'][0] = {
            'prev_out'  => { 'hash' => hth(i[0]), 'n' => i[1] },
            'coinbase' => i[3].unpack("H*")[0]
          }
        end
        h
      end

      def hth(s)
        s.reverse.unpack('H*')[0]
      end

      # generates rawblock json as seen in the block explorer.
      def to_json
        JSON.pretty_generate( to_hash, :space => '' )
      end

      def self.from_hash(h)
        tx = new(nil)
        tx.ver, tx.lock_time = *h.values_at('ver', 'lock_time')
        h['in'].each{|input|
          if input['coinbase']
            coinbase_data = [ input['coinbase'] ].pack("H*")
            tx.add_in( [ htb(input['prev_out']['hash']), input['prev_out']['n'], coinbase_data.bytesize, coinbase_data ] )
          else
            script_data = Script.binary_from_string(input['scriptSig'])
            tx.add_in( [ htb(input['prev_out']['hash']), input['prev_out']['n'], script_data.bytesize, script_data ] )
          end
        }
        h['out'].each{|output|
          script_data = Script.binary_from_string(output['scriptPubKey'])
          tx.add_out( [ (output['value'].to_f * 100000000.0).to_i, script_data.bytesize, script_data ] )
        }
        tx.instance_eval{ @hash = hash_from_payload(@payload = to_payload) }
        tx
      end

      def self.binary_from_hash(h); from_hash(h).to_payload; end
      def self.from_json(json_string); from_hash( JSON.load(json_string) ); end
      def self.binary_from_json(json_string); from_json(json_string).to_payload; end

      def self.htb(s)
        [s].pack('H*').reverse
      end
    end

  end
end

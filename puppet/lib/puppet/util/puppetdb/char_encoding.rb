module Puppet
module Util
module Puppetdb
module CharEncoding


   # Some of this code is modeled after:
   #  https://github.com/brianmario/utf8/blob/ef10c033/ext/utf8/utf8proc.c
   #  https://github.com/brianmario/utf8/blob/ef10c033/ext/utf8/string_utf8.c

   Utf8CharLens = [
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
       2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
       3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
       4, 4, 4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0
   ]

   Utf8ReplacementChar = [ 0xEF, 0xBF, 0xBD ].pack("c*")


   def self.utf8_string(str)
     if RUBY_VERSION =~ /1.8/
       # Ruby 1.8 doesn't have String#encode and related methods, and there
       #  appears to be a bug in iconv that will interpret some byte sequences
       #  as 6-byte characters.  Thus, we are forced to resort to some unfortunate
       #  manual chicanery.
       warn_if_changed(str, ruby18_clean_utf8(str))
     elsif str.encoding == Encoding::UTF_8
       # If we get here, we're in ruby 1.9+, so we have the string encoding methods
       #  available.  However, just because  a ruby String object is already
       #  marked as UTF-8, that doesn't guarantee that its contents are actually
       #  valid; and if you call ruby's ".encode" method with an encoding of
       #  "utf-8" for a String that ruby already believes is UTF-8, ruby
       #  seems to optimize that to be a no-op.  So, we have to do some more
       #  complex handling...

       # If the string already has valid encoding then we're fine.
       return str if str.valid_encoding?

       # If not, we basically have to walk over the characters and replace
       #  them by hand.
       warn_if_changed(str, str.each_char.map { |c| c.valid_encoding? ? c : "\ufffd"}.join)
     else
       # if we get here, we're ruby 1.9 and the current string is *not* encoded
       #  as UTF-8.  Thus we can actually rely on ruby's "encode" method.
       begin
         str.encode('UTF-8')
       rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => e
         # If we got an exception, the string is either invalid or not
         # convertible to UTF-8, so drop those bytes.
         warn_if_changed(str, str.encode('UTF-8', :invalid => :replace, :undef => :replace))
       end
     end
   end

   private

   def self.warn_if_changed(str, converted_str)
     if converted_str != str
       Puppet.warning "Ignoring invalid UTF-8 byte sequences in data to be sent to PuppetDB"
     end
     converted_str
   end

   def self.ruby18_clean_utf8(str)
     #iconv_to_utf8(str)
     ruby18_manually_clean_utf8(str)
   end


   # TODO: we're not using this anymore, but I wanted to leave it around
   #  for a little while just to make sure that the new code pans out.
   def self.iconv_to_utf8(str)
     iconv = Iconv.new('UTF-8//IGNORE', 'UTF-8')

     # http://po-ru.com/diary/fixing-invalid-utf-8-in-ruby-revisited/
     iconv.iconv(str + " ")[0..-2]
   end

   def self.get_char_len(byte)
     Utf8CharLens[byte]
   end

   # Manually cleans a string by replacing any byte sequences that are not
   #  valid UTF-8 characters with the unicode replacement character.  Due
   #  to differences in how the [] operator works on strings in ruby 1.8 vs.
   #  ruby 1.9, this method will NOT work with ruby 1.9.
   def self.ruby18_manually_clean_utf8(str)
     i = 0
     len = str.length
     result = ""

     while i < len
       byte = str[i]
       i += 1

       char_len = get_char_len(byte)
       case char_len
       when 0
         result.concat(Utf8ReplacementChar)
       when 1
         result << byte
       when 2..4
         ruby18_handle_multibyte_char(result, byte, str, i,  char_len)
         i += char_len
       else
         raise Puppet::DevError, "Unhandled UTF8 char length: '#{char_len}'"
       end

     end

     result
   end

  def self.ruby18_handle_multibyte_char(result_str, byte, str, i, char_len)
    # keeping an array of bytes for now because we need to do some
    #  bitwise math on them.
    char_additional_bytes = []

    # If we don't have enough bytes left to read the full character, we
    #  put on a replacement character and bail.
    if i + (char_len - 1) > str.length
      result_str.concat(Utf8ReplacementChar)
      return
    end

    # we've already read the first byte, so we need to set up a range
    #  from 0 to (n-2); e.g. if it's a 2-byte char, we will have a range
    #  from 0 to 0 which will result in reading 1 more byte
    (0..char_len - 2).each do |x|
      char_additional_bytes << str[i + x]
    end

    if (is_valid_multibyte_suffix(char_additional_bytes))
      result_str << byte
      result_str.concat(char_additional_bytes.pack("c*"))
    else
      result_str.concat(Utf8ReplacementChar)
    end
  end

  def self.is_valid_multibyte_suffix(bytes)
    bytes.all? { |b| ((b & 0xC0) == 0x80) }
  end

end
end
end
end
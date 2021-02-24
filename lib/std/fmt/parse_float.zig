// This is a port and adaption of Ulf Adams's "ryu" float parser:
// https://github.com/ulfjack/ryu
// which is licensed under the Boost Software License.

// Boost Software License - Version 1.0 - August 17th, 2003
//
// Permission is hereby granted, free of charge, to any person or organization
// obtaining a copy of the software and accompanying documentation covered by
// this license (the "Software") to use, reproduce, display, distribute,
// execute, and transmit the Software, and to prepare derivative works of the
// Software, and to permit third-parties to whom the Software is furnished to
// do so, all subject to the following:
//
// The copyright notices in the Software and this entire statement, including
// the above license grant, this restriction and the following disclaimer,
// must be included in all copies of the Software, in whole or in part, and
// all derivative works of the Software, unless such copies or derivative
// works are solely in the form of machine-executable object code generated by
// a source language processor.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
// SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
// FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

// This implementation guarantees exact round-to-closest behaviour if the input
// does not have more than the appropriate significant digits before the
// exponent. These are:
// f16: 5 digits, f32: 9 digits, f64: 17 digits, f128: ? digits

const std = @import("../std.zig");
const caseInEql = std.ascii.eqlIgnoreCase;
const assert = std.debug.assert;

usingnamespace @import("ryu_helpers.zig");


pub fn parseFloat(comptime T: type, s: []const u8) !T {
    if (s.len == 0) {
        return error.InvalidCharacter;
    }

    if (caseInEql(s, "nan")) {
        return std.math.nan(T);
    } else if (caseInEql(s, "inf") or caseInEql(s, "+inf")) {
        return std.math.inf(T);
    } else if (caseInEql(s, "-inf")) {
        return -std.math.inf(T);
    }
    return switch (T) {
        f16 => @floatCast(f16, try stringToFloat(f32, s)),
        f128 => @floatCast(f128, try stringToFloat(f64, s)),

        else => stringToFloat(T, s),
    };
}

fn stringToFloat(comptime T: type, s: []const u8) !T {
    return @bitCast(T, try stringToIeee(PropertiesOf(T), s));
}

fn stringToIeee(comptime float: FloatProperties, buf: []const u8) !float.integer {
    const int = float.integer;

    if (buf.len == 0) {
        return error.InvalidCharacter;
    }
    var mantissa_digits: i32 = 0;
    var dot_index: usize = buf.len;
    var mantissa: int = 0;
    var mantissa_sign = false;
    var end_index: usize = buf.len;
    var i: usize = 0;

    if (buf[i] == '-') {
        mantissa_sign = true;
        i += 1;
    } else if (buf[i] == '+') {
        i += 1;
    }

    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == '.') {
            if (dot_index != buf.len) {
                return error.InvalidCharacter;
            }
            dot_index = i;
            continue;
        }

        if (c < '0' or c > '9') {
            break;
        }
        if (mantissa_digits < float.significant_digits) {
            mantissa = 10 * mantissa + (c - '0');
            if (mantissa != 0) {
                mantissa_digits += 1;
            }
        } else {
            // Ignore the following digits; without bignums, we can't guarantee correct round-to-closest here anyways.
            if (end_index == buf.len) {
                end_index = i;
            }
        }
    }
    if (dot_index == buf.len) {
        dot_index = i;
    }

    var exponent_digits: i32 = 0;
    var exponent: i32 = 0;
    var exponent_sign = false;

    if (i < buf.len and (buf[i] == 'e' or buf[i] == 'E')) {
        if (end_index == buf.len) {
            end_index = i;
        }
        i += 1;
        if (i < buf.len and (buf[i] == '-' or buf[i] == '+')) {
            exponent_sign = buf[i] == '-';
            i += 1;
        }
        while (i < buf.len) : (i += 1) {
            const c = buf[i];
            if (c < '0' or c > '9') {
                return error.InvalidCharacter;
            }
            if (exponent_digits > 5) {
                const r =
                    if (exponent_sign or mantissa == 0)
                        0.0
                    else
                        std.math.inf(float.T);
                const sr = if (mantissa_sign) -r else r;
                // TODO: File bug report:
                // return @bitCast(u32, if (mantissa_sign) -r else r) 
                // leads to compiler crash!
                return @bitCast(int, sr);
            }
            exponent = 10 * exponent + @as(i32, (c - '0'));
            if (exponent != 0) {
                exponent_digits += 1;
            }
        }
    }
    if (i < buf.len) {
        return error.InvalidCharacter;
    }
    if (exponent_sign) {
        exponent = -exponent;
    }

    if (end_index > dot_index) {
        end_index -= 1;
    }
    exponent -= @intCast(i32, end_index - dot_index);


    if ((mantissa_digits + exponent <= float.min_dec_exponent) or (mantissa == 0)) {
        // Number is less than representable and should be rounded down to 0; return +/-0.0.
        return @as(int, @boolToInt(mantissa_sign)) << (float.exponent_bits + float.mantissa_bits);
    }
    if (mantissa_digits + exponent >= float.max_dec_exponent) {
        // Number is larger than representable and should be rounded to +/-Infinity.
        return (@as(int, @boolToInt(mantissa_sign)) << (float.exponent_bits + float.mantissa_bits))
                    | (float.max_exponent << float.mantissa_bits);
    }

    return toIeee(float, ryuCore(float, exponent, mantissa), mantissa_sign);
}

fn BinRepr(comptime float: FloatProperties) type {
    return struct {
        mantissa: float.integer,
        /// base 2
        exponent: i32,
        /// Whether the conversion was exact
        is_exact: bool
    };
}

/// Converts base 10 floats to base 2 floats
fn ryuCore(comptime float: FloatProperties, dec_exp: i32, dec_mant: float.integer) BinRepr(float) {
    const int = float.integer;
    var bin: BinRepr(float) = undefined;

    if (dec_exp >= 0) {
        // The length of m * 10^e in bits is:
        //   log2(dec_mant * 10^dec_exp)
        // = log2(dec_mant) + dec_exp * log2(10)
        // = log2(dec_mant) + dec_exp + dec_exp * log2(5)
        // We round down so that we get at least the necessary amount of bits.
        const bitlength = floor_log2(int, dec_mant) + dec_exp + log2pow5(@intCast(u32, dec_exp));

        // We want to compute the (mantissa_bits + 1) top-most bits (+1 for the implicit leading
        // one in IEEE format). We therefore choose a binary output exponent of
        bin.exponent = bitlength - (float.mantissa_bits + 1);

        // bin_mant = floor(dec_mant * 10^dec_exp / 2^bin_exp)
        //          = floor(dec_mant * 5^dec_exp / 2^(bin_exp-dec_exp)).
        bin.mantissa = mulPow5divPow2(int, dec_mant, @intCast(u32, dec_exp), bin.exponent - dec_exp);

        // We also compute if the result is exact, i.e. the above floor(...) did not cut off
        // a fractional part. This is given iff 2^(bin_exp-dec_exp) divides dec_mant.
        bin.is_exact = multipleOfPowerOf2(int, dec_mant, bin.exponent - dec_exp);

    } else {
        const bitlength = floor_log2(int, dec_mant) + dec_exp - ceil_log2pow5(@intCast(u32, -dec_exp));
        bin.exponent = bitlength - (float.mantissa_bits + 1);

        // bin_mant = floor(dec_mant * 10^dec_exp / 2^bin_exp)
        //          = floor(dec_mant / ( 5^(-dec_exp) * 2^(bin_exp-dec_exp) ))
        bin.mantissa = mulPow5InvDivPow2(int, dec_mant, @intCast(u32, -dec_exp), bin.exponent - dec_exp);

        bin.is_exact = multipleOfPowerOf2(int, dec_mant, bin.exponent - dec_exp)
                    and multipleOfPowerOf5(int, dec_mant, @intCast(u32, -dec_exp));
    }
    return bin;
}

fn toIeee(comptime float: FloatProperties, bin: BinRepr(float), mantissa_sign: bool) float.integer {
    const int = float.integer;

    var is_exact: bool = bin.is_exact;
    var ieee_exp = @intCast(int, std.math.max(0, bin.exponent + float.exponent_bias + floor_log2(int, bin.mantissa)));

    if (ieee_exp > float.max_exponent - 1) {
        // Final IEEE exponent is larger than the maximum representable; return +/-Infinity.
        return (@as(int, @boolToInt(mantissa_sign)) << (float.exponent_bits + float.mantissa_bits)) | (0xff << float.mantissa_bits);
    }

    // Figure out how much we need to shift bin.mantissa. To take the final IEEE exponent into account, 
    // we need to reverse the bias and also special-case the value 0.
    const bshift = if (ieee_exp == 0) 1 else @intCast(i32, ieee_exp);
    const valshift = bshift - bin.exponent - float.exponent_bias - float.mantissa_bits;
    const shift = @intCast(u5, valshift);
    assert(shift >= 1);

    // We need to round up if the exact value is more than 0.5 above the value we computed. That's
    // equivalent to checking if the last removed bit was 1 and either the value was not just
    // trailing zeros or the result would otherwise be odd.
    //
    // We need to update is_exact given that we have the exact output exponent ieee_exp now.
    is_exact = is_exact and (bin.mantissa & ((@as(int, 1) << (shift - 1)) - 1)) == 0;
    // TODO: Explain
    const lastRemovedBit = (bin.mantissa >> (shift - 1)) & 1;
    const roundUp = (lastRemovedBit != 0) and (!is_exact or (((bin.mantissa >> shift) & 1) != 0));

    var ieee_mant = (bin.mantissa >> shift) + @boolToInt(roundUp);
    assert(ieee_mant <= (1 << (float.mantissa_bits + 1)));

    ieee_mant &= (1 << float.mantissa_bits) - 1;
    if (ieee_mant == 0 and roundUp) {
        // Rounding up may overflow the mantissa.
        // In this case we move a trailing zero of the mantissa into the exponent.
        // Due to how the IEEE represents +/-Infinity, we don't need to check for overflow here.
        ieee_exp += 1;
    }
    return (((@as(int, @boolToInt(mantissa_sign)) << float.exponent_bits) | ieee_exp) << float.mantissa_bits) | ieee_mant;
}


test "fmt.parseFloat" {
    const testing = std.testing;
    const expect = testing.expect;
    const expectEqual = testing.expectEqual;
    const approxEqAbs = std.math.approxEqAbs;
    const epsilon = 1e-7;

    inline for ([_]type{ f16, f32, f64, f128 }) |T| {
        const Z = std.meta.Int(.unsigned, @typeInfo(T).Float.bits);

        testing.expectError(error.InvalidCharacter, parseFloat(T, ""));
        testing.expectError(error.InvalidCharacter, parseFloat(T, "   1"));
        testing.expectError(error.InvalidCharacter, parseFloat(T, "1abc"));

        expectEqual(try parseFloat(T, "0"), 0.0);
        expectEqual(try parseFloat(T, "0"), 0.0);
        expectEqual(try parseFloat(T, "+0"), 0.0);
        expectEqual(try parseFloat(T, "-0"), 0.0);
 
        expectEqual(try parseFloat(T, "0e0"), 0);
        expectEqual(try parseFloat(T, "2e3"), 2000.0);
        expectEqual(try parseFloat(T, "1.5"), 1.5);
        expectEqual(try parseFloat(T, "1e0"), 1.0);
        expectEqual(try parseFloat(T, "-2e3"), -2000.0);
        expectEqual(try parseFloat(T, "-1e0"), -1.0);
        expectEqual(try parseFloat(T, "1.234e3"), 1234);

        expect(approxEqAbs(T, try parseFloat(T, "3.141"), 3.141, epsilon));
        expect(approxEqAbs(T, try parseFloat(T, "-3.141"), -3.141, epsilon));

        expectEqual(try parseFloat(T, "1e-700"), 0);
        expectEqual(try parseFloat(T, "1e+700"), std.math.inf(T));

        expectEqual(@bitCast(Z, try parseFloat(T, "nAn")), @bitCast(Z, std.math.nan(T)));
        expectEqual(try parseFloat(T, "inF"), std.math.inf(T));
        expectEqual(try parseFloat(T, "-INF"), -std.math.inf(T));

        expectEqual(try parseFloat(T, "0.4e0066999999999999999999999999999999999999999999999999999"), std.math.inf(T));

        if (T != f16) {
            expect(approxEqAbs(T, try parseFloat(T, "1e-2"), 0.01, epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "1234e-2"), 12.34, epsilon));

            expect(approxEqAbs(T, try parseFloat(T, "123142.1"), 123142.1, epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "1231421."), 1231421, epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "1231421.e0"), 1231421, epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "-123142.1124"), @as(T, -123142.1124), epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "0.7062146892655368"), @as(T, 0.7062146892655368), epsilon));
            expect(approxEqAbs(T, try parseFloat(T, "2.71828182845904523536"), @as(T, 2.718281828459045), epsilon));
        }
    }
}

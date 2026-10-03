using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Numerics;
using System.Text;

namespace AuroraDataTool
{
    public sealed class ColumnSpec
    {
        public string Table { get; set; }
        public string Name { get; set; }
        public int Ordinal { get; set; }
        public string DataType { get; set; }
        public string ColumnType { get; set; }
        public string IsNullable { get; set; }
        public string ColumnKey { get; set; }
        public string Extra { get; set; }
        public string ColumnDefault { get; set; }
        public string CharLength { get; set; }
        public string NumPrecision { get; set; }
        public string NumScale { get; set; }
        public string DatetimePrecision { get; set; }
        public string IsUnsigned { get; set; }
        public string IsGenerated { get; set; }
        public string IsAutoIncrement { get; set; }
        public string EnumValues { get; set; }
        public string FkTable { get; set; }
        public string FkColumn { get; set; }
        public string Strategy { get; set; }
        public string ConstValue { get; set; }
        public string RangeMin { get; set; }
        public string RangeMax { get; set; }
        public string UniqueMode { get; set; }
        public string UniqueStart { get; set; }
        public string UniqueStep { get; set; }
        public string UniquePrefix { get; set; }
        public string UniquePad { get; set; }
        public string ChoiceList { get; set; }
        public string Template { get; set; }
        public string Pattern { get; set; }
        public string NullRatio { get; set; }
        public string StringLength { get; set; }
        public string StringMinLength { get; set; }
        public string StringMaxLength { get; set; }
        public string ReferenceTable { get; set; }
        public string ReferenceColumn { get; set; }
        public string ReferenceMode { get; set; }
        public string ReferenceStart { get; set; }
        public string ReferenceCount { get; set; }
        public string ReferenceStep { get; set; }
        public string[] ReferenceValues { get; set; }
        public string Expression { get; set; }
        public string Include { get; set; }
        public string Overflow { get; set; }
        public string UniqueSuffix { get; set; }
        public string Notes { get; set; }
        public string Transport { get; set; }
    }

    public sealed class ToolResult
    {
        public bool Ok;
        public List<string> Errors = new List<string>();
        public List<string> Warnings = new List<string>();
        public long RowCount;
        public string[] OutputColumns = new string[0];
    }

    public sealed class Rng64
    {
        // xorshift64* . State is a full 64-bit word. Next() wraps modulo 2^64.
        ulong _state;

        public Rng64(ulong state)
        {
            if (state == 0) state = 0x9E3779B97F4A7C15UL;
            _state = state;
        }

        public static ulong SplitMix(ulong z)
        {
            z += 0x9E3779B97F4A7C15UL;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }

        // FNV-1a 64 mixed with the job seed, then one SplitMix. Same bytes on every platform.
        public static ulong Mix(ulong seed, string text)
        {
            ulong h = 14695981039346656037UL;
            h ^= seed;
            h *= 1099511628211UL;
            byte[] bytes = Encoding.UTF8.GetBytes(text ?? "");
            for (int i = 0; i < bytes.Length; i++)
            {
                h ^= bytes[i];
                h *= 1099511628211UL;
            }
            if (h == 0) h = 0x9E3779B97F4A7C15UL;
            return SplitMix(h);
        }

        public static Rng64 ForTable(ulong jobSeed, string tableName)
        {
            return new Rng64(Mix(jobSeed, tableName ?? ""));
        }

        public ulong Next()
        {
            ulong x = _state;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            _state = x;
            return x * 0x2545F4914F6CDD1DUL;
        }

        public ulong NextBounded(ulong bound)
        {
            if (bound == 0) throw new InvalidOperationException("bound is 0");
            if (bound == 1) return 0;
            ulong limit = ulong.MaxValue - (ulong.MaxValue % bound);
            ulong r;
            do { r = Next(); } while (r >= limit);
            return r % bound;
        }

        public BigInteger NextBoundedBig(BigInteger bound)
        {
            if (bound <= 0) throw new InvalidOperationException("bound is 0");
            if (bound <= ulong.MaxValue) return new BigInteger(NextBounded((ulong)bound));
            BigInteger max = BigInteger.One << 128;
            if (bound > max) throw new InvalidOperationException("range is wider than 128 bits");
            BigInteger limit = max - (max % bound);
            while (true)
            {
                ulong hi = Next();
                ulong lo = Next();
                BigInteger r = (new BigInteger(hi) << 64) + new BigInteger(lo);
                if (r < limit) return r % bound;
            }
        }
    }

    public static class Sql
    {
        public static string QuoteIdent(string name)
        {
            if (name == null || name.Length == 0)
                throw new InvalidOperationException("Identifier is empty.");
            for (int i = 0; i < name.Length; i++)
            {
                char c = name[i];
                if (c == '\0' || c == ';' || c == '\r' || c == '\n')
                    throw new InvalidOperationException("Identifier contains a character that cannot be quoted safely: " + name);
            }
            return "`" + name.Replace("`", "``") + "`";
        }

        public static string QuoteQualified(string database, string table)
        {
            if (string.IsNullOrEmpty(database)) return QuoteIdent(table);
            return QuoteIdent(database) + "." + QuoteIdent(table);
        }

        // Caller must have set sql_mode to include NO_BACKSLASH_ESCAPES.
        public static string Literal(string value, bool isNull, string dataType)
        {
            if (isNull || value == null) return "NULL";
            if (IsBareNumeric(dataType, value)) return value;
            return "'" + value.Replace("'", "''") + "'";
        }

        public static bool IsBareNumeric(string dataType, string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            string dt = (dataType ?? "").ToLowerInvariant();
            if (!(dt == "tinyint" || dt == "smallint" || dt == "mediumint" || dt == "int" || dt == "integer"
                || dt == "bigint" || dt == "decimal" || dt == "numeric" || dt == "float" || dt == "double"
                || dt == "real" || dt == "year" || dt == "bit"))
                return false;
            int i = 0;
            if (value[0] == '-')
            {
                if (value.Length == 1) return false;
                i = 1;
            }
            bool dot = false;
            int digits = 0;
            for (; i < value.Length; i++)
            {
                char c = value[i];
                if (c == '.')
                {
                    if (dot) return false;
                    dot = true;
                    continue;
                }
                if (c < '0' || c > '9') return false;
                digits++;
            }
            if (digits == 0) return false;
            if (value.Length > 1 && value[0] == '0' && value[1] != '.') return false;
            if (value.Length > 2 && value[0] == '-' && value[1] == '0' && value[2] != '.') return false;
            return true;
        }
    }

    static class SpecUtil
    {
        public static string Dt(ColumnSpec c)
        {
            return (c.DataType ?? "").Trim().ToLowerInvariant();
        }

        public static bool Yes(string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            return value.Equals("YES", StringComparison.OrdinalIgnoreCase)
                || value.Equals("Y", StringComparison.OrdinalIgnoreCase)
                || value.Equals("TRUE", StringComparison.OrdinalIgnoreCase)
                || value == "1";
        }

        public static bool No(string value)
        {
            return !Yes(value);
        }

        public static bool IsGenerated(ColumnSpec c)
        {
            if (Yes(c.IsGenerated)) return true;
            string extra = (c.Extra ?? "").ToLowerInvariant();
            // DEFAULT_GENERATED is a normal default, not a generated column.
            return extra.IndexOf("virtual generated") >= 0 || extra.IndexOf("stored generated") >= 0;
        }

        public static bool IsAutoInc(ColumnSpec c)
        {
            if (Yes(c.IsAutoIncrement)) return true;
            return (c.Extra ?? "").ToLowerInvariant().IndexOf("auto_increment") >= 0;
        }

        public static bool IsGeometry(ColumnSpec c)
        {
            switch (Dt(c))
            {
                case "geometry":
                case "point":
                case "linestring":
                case "polygon":
                case "multipoint":
                case "multilinestring":
                case "multipolygon":
                case "geomcollection":
                case "geometrycollection":
                    return true;
                default:
                    return false;
            }
        }

        public static bool IsInteger(string dt)
        {
            return dt == "tinyint" || dt == "smallint" || dt == "mediumint" || dt == "int" || dt == "integer" || dt == "bigint";
        }

        public static bool IsDecimalFamily(string dt)
        {
            return dt == "decimal" || dt == "numeric" || dt == "float" || dt == "double" || dt == "real";
        }

        public static bool IsString(string dt)
        {
            return dt == "char" || dt == "varchar" || dt == "tinytext" || dt == "text" || dt == "mediumtext" || dt == "longtext";
        }

        public static bool IsBinary(string dt)
        {
            return dt == "binary" || dt == "varbinary" || dt == "tinyblob" || dt == "blob" || dt == "mediumblob" || dt == "longblob";
        }

        public static bool IsTinyInt1(ColumnSpec c)
        {
            string ct = (c.ColumnType ?? "").ToLowerInvariant().Replace(" ", "");
            return ct.StartsWith("tinyint(1)") || ct.StartsWith("boolean") || ct == "bool";
        }

        public static bool IsPri(ColumnSpec c)
        {
            return string.Equals(c.ColumnKey, "PRI", StringComparison.OrdinalIgnoreCase);
        }

        public static bool IsUni(ColumnSpec c)
        {
            return string.Equals(c.ColumnKey, "UNI", StringComparison.OrdinalIgnoreCase);
        }

        public static bool HasDefault(ColumnSpec c)
        {
            return !string.IsNullOrEmpty(c.ColumnDefault) || (c.Extra ?? "").ToLowerInvariant().IndexOf("default_generated") >= 0
                || (c.Extra ?? "").ToLowerInvariant().IndexOf("auto_increment") >= 0;
        }

        public static int IntOr(string text, int fallback)
        {
            int n;
            if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) return n;
            return fallback;
        }

        public static string[] SplitPipes(string text)
        {
            if (string.IsNullOrEmpty(text)) return new string[0];
            string[] parts = text.Split('|');
            List<string> list = new List<string>();
            for (int i = 0; i < parts.Length; i++)
            {
                string p = parts[i].Trim();
                if (p.Length == 0) continue;
                if (p == "$EMPTY$") p = "";
                list.Add(p);
            }
            return list.ToArray();
        }
    }

    public static class StrategyResolver
    {
        public static void Resolve(ColumnSpec c, List<string> warnings)
        {
            if (c == null) throw new ArgumentNullException("c");
            if (warnings == null) warnings = new List<string>();
            if (string.IsNullOrEmpty(c.Include)) c.Include = "YES";
            else c.Include = YesNo(c.Include);
            if (string.IsNullOrEmpty(c.Overflow)) c.Overflow = "error";
            if (string.IsNullOrEmpty(c.UniqueStep)) c.UniqueStep = "1";
            bool wasAuto = string.IsNullOrEmpty(c.Strategy) || c.Strategy.Trim().Equals("auto", StringComparison.OrdinalIgnoreCase);
            if (wasAuto) c.Strategy = ChooseAuto(c);
            c.Strategy = (c.Strategy ?? "").Trim().ToLowerInvariant();
            Fill(c, warnings);
            if (wasAuto)
            {
                if (string.IsNullOrEmpty(c.Notes)) c.Notes = "[auto]";
                else if (c.Notes.IndexOf("[auto]") < 0) c.Notes = c.Notes + " [auto]";
            }
        }

        static string YesNo(string value)
        {
            return SpecUtil.Yes(value) ? "YES" : "NO";
        }

        static string ChooseAuto(ColumnSpec c)
        {
            if (SpecUtil.IsGenerated(c)) return "skip";
            if (SpecUtil.IsGeometry(c)) return "skip";
            // Explicit ids keep dumps, child foreign keys, and post-test cleanup deterministic.
            // MySQL accepts inserted values in an AUTO_INCREMENT column and advances the counter.
            if (SpecUtil.IsAutoInc(c) && SpecUtil.IsInteger(SpecUtil.Dt(c))) return "unique";
            if (SpecUtil.IsAutoInc(c)) return "skip";
            if (!string.IsNullOrEmpty(c.FkTable) && !string.IsNullOrEmpty(c.FkColumn))
            {
                if (string.IsNullOrEmpty(c.ReferenceTable)) c.ReferenceTable = c.FkTable;
                if (string.IsNullOrEmpty(c.ReferenceColumn)) c.ReferenceColumn = c.FkColumn;
                return "reference";
            }
            string dt = SpecUtil.Dt(c);
            bool key = SpecUtil.IsPri(c) || SpecUtil.IsUni(c);
            if (key && SpecUtil.IsInteger(dt)) return "unique";
            if (key && (SpecUtil.IsString(dt) || SpecUtil.IsBinary(dt)))
            {
                if (string.IsNullOrEmpty(c.UniqueMode)) c.UniqueMode = "sequence_prefixed";
                return "unique";
            }
            if (dt == "enum" || dt == "set") return "choice";
            if (SpecUtil.IsTinyInt1(c)) return "choice";
            if (SpecUtil.IsInteger(dt) || dt == "bit" || dt == "year") return "range";
            if (SpecUtil.IsDecimalFamily(dt)) return "range";
            if (dt == "date" || dt == "datetime" || dt == "timestamp" || dt == "time") return "datetime";
            if (dt == "json") return "template";
            if (SpecUtil.IsString(dt) || SpecUtil.IsBinary(dt))
            {
                string n = (c.Name ?? "").ToLowerInvariant();
                if (n.IndexOf("uuid") >= 0 || n.IndexOf("guid") >= 0)
                {
                    c.UniqueMode = string.IsNullOrEmpty(c.UniqueMode) ? "uuid" : c.UniqueMode;
                    return "unique";
                }
                if (n.IndexOf("email") >= 0) return "template";
                if (n.IndexOf("phone") >= 0 || n.IndexOf("tel") >= 0 || n.IndexOf("zip") >= 0 || n.IndexOf("postal") >= 0)
                    return "pattern";
                return "random";
            }
            return "skip";
        }

        static void Fill(ColumnSpec c, List<string> warnings)
        {
            string dt = SpecUtil.Dt(c);
            if (c.Strategy == "unique") FillUnique(c, dt);
            else if (c.Strategy == "choice") FillChoice(c);
            else if (c.Strategy == "range") FillRange(c, dt, warnings);
            else if (c.Strategy == "datetime") FillDate(c, dt);
            else if (c.Strategy == "template") FillTemplate(c, dt);
            else if (c.Strategy == "pattern") FillPattern(c);
            else if (c.Strategy == "random") FillRandom(c, dt);
            else if (c.Strategy == "reference")
            {
                if (string.IsNullOrEmpty(c.ReferenceTable)) c.ReferenceTable = c.FkTable;
                if (string.IsNullOrEmpty(c.ReferenceColumn)) c.ReferenceColumn = c.FkColumn;
                if (string.IsNullOrEmpty(c.ReferenceStep)) c.ReferenceStep = "1";
            }
        }

        static void FillUnique(ColumnSpec c, string dt)
        {
            if (string.IsNullOrEmpty(c.UniqueMode))
            {
                string n = (c.Name ?? "").ToLowerInvariant();
                if (n.IndexOf("uuid") >= 0 || n.IndexOf("guid") >= 0) c.UniqueMode = "uuid";
                else if (SpecUtil.IsInteger(dt) || dt == "year" || dt == "bit") c.UniqueMode = "sequence";
                else c.UniqueMode = "sequence_prefixed";
            }
            else c.UniqueMode = c.UniqueMode.Trim().ToLowerInvariant();
            if (c.UniqueMode == "sequence_prefixed")
            {
                if (string.IsNullOrEmpty(c.UniquePrefix))
                {
                    string raw = c.Name ?? "C";
                    if (raw.Length > 3) raw = raw.Substring(0, 3);
                    c.UniquePrefix = raw.ToUpperInvariant() + "_";
                }
                if (string.IsNullOrEmpty(c.UniquePad)) c.UniquePad = "8";
            }
        }

        static void FillChoice(ColumnSpec c)
        {
            if (string.IsNullOrEmpty(c.ChoiceList) && !string.IsNullOrEmpty(c.EnumValues))
                c.ChoiceList = c.EnumValues;
            if (string.IsNullOrEmpty(c.ChoiceList) && SpecUtil.IsTinyInt1(c))
                c.ChoiceList = "0|1";
        }

        static void FillRange(ColumnSpec c, string dt, List<string> warnings)
        {
            if (dt == "year")
            {
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "2020";
                if (string.IsNullOrEmpty(c.RangeMax)) c.RangeMax = "2026";
                return;
            }
            if (dt == "bit")
            {
                int bits = BitWidth(c);
                BigInteger full = (BigInteger.One << bits) - 1;
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "0";
                if (string.IsNullOrEmpty(c.RangeMax))
                {
                    BigInteger cap = full > 1000000 ? new BigInteger(1000000) : full;
                    c.RangeMax = cap.ToString();
                }
                return;
            }
            if (SpecUtil.IsInteger(dt))
            {
                BigInteger tMin, tMax;
                IntegerBounds(c, dt, out tMin, out tMax);
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "0";
                if (string.IsNullOrEmpty(c.RangeMax))
                {
                    BigInteger cap = tMax > 1000000 ? new BigInteger(1000000) : tMax;
                    if (cap < 0) cap = tMax;
                    c.RangeMax = cap.ToString();
                }
                return;
            }
            if (SpecUtil.IsDecimalFamily(dt))
            {
                int scale = ScaleOf(c, dt);
                BigInteger tMaxUnits = DecimalMaxUnits(c, dt, scale);
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = FormatUnits(BigInteger.Zero, scale);
                if (string.IsNullOrEmpty(c.RangeMax))
                {
                    BigInteger want = ToUnits(100000m, scale);
                    if (tMaxUnits >= 0 && want > tMaxUnits) want = tMaxUnits;
                    c.RangeMax = FormatUnits(want, scale);
                }
            }
        }

        static void FillDate(ColumnSpec c, string dt)
        {
            if (dt == "time")
            {
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "00:00:00";
                if (string.IsNullOrEmpty(c.RangeMax)) c.RangeMax = "23:59:59";
                return;
            }
            if (dt == "date")
            {
                if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "2024-01-01";
                if (string.IsNullOrEmpty(c.RangeMax)) c.RangeMax = "2026-12-31";
                return;
            }
            if (string.IsNullOrEmpty(c.RangeMin)) c.RangeMin = "2024-01-01 00:00:00";
            if (string.IsNullOrEmpty(c.RangeMax)) c.RangeMax = "2026-12-31 23:59:59";
        }

        static void FillTemplate(ColumnSpec c, string dt)
        {
            if (!string.IsNullOrEmpty(c.Template)) return;
            if (dt == "json")
            {
                c.Template = "{\"n\":{seq}}";
                return;
            }
            string n = (c.Name ?? "").ToLowerInvariant();
            if (n.IndexOf("email") >= 0)
            {
                int len = SpecUtil.IntOr(c.CharLength, 255);
                c.Template = len >= 18 ? "user{seq}@example.test" : "u{seq}@e.test";
            }
        }

        static void FillPattern(ColumnSpec c)
        {
            if (!string.IsNullOrEmpty(c.Pattern)) return;
            string n = (c.Name ?? "").ToLowerInvariant();
            int len = SpecUtil.IntOr(c.CharLength, 32);
            if (n.IndexOf("phone") >= 0 || n.IndexOf("tel") >= 0)
                c.Pattern = len >= 13 ? "090-####-####" : new string('#', Math.Max(1, len));
            else if (n.IndexOf("zip") >= 0 || n.IndexOf("postal") >= 0)
                c.Pattern = len >= 8 ? "###-####" : new string('#', Math.Max(1, len));
        }

        static void FillRandom(ColumnSpec c, string dt)
        {
            if (!string.IsNullOrEmpty(c.StringLength)) return;
            if (!string.IsNullOrEmpty(c.StringMinLength) && !string.IsNullOrEmpty(c.StringMaxLength)) return;
            int charLen = SpecUtil.IntOr(c.CharLength, 0);
            int len;
            if (SpecUtil.IsBinary(dt) || dt == "text" || dt == "tinytext" || dt == "mediumtext" || dt == "longtext"
                || charLen <= 0 || charLen > 64)
                len = 16;
            else
                len = Math.Min(12, charLen);
            if (charLen > 0 && len > charLen) len = charLen;
            if (len < 1) len = 1;
            c.StringLength = len.ToString(CultureInfo.InvariantCulture);
        }

        public static List<string> Validate(ColumnSpec c, long rowCount)
        {
            List<string> errors = new List<string>();
            if (c == null)
            {
                errors.Add("Column spec is missing.");
                return errors;
            }
            string where = (c.Table ?? "?") + "." + (c.Name ?? "?");
            if (string.IsNullOrEmpty(c.Name)) errors.Add(where + ": column name is empty.");
            if (SpecUtil.No(c.Include) || c.Strategy == "skip")
            {
                if (SpecUtil.No(c.IsNullable) && !SpecUtil.IsAutoInc(c) && !SpecUtil.IsGenerated(c) && !SpecUtil.HasDefault(c))
                    errors.Add(where + ": NOT NULL column is omitted and has no default.");
                return errors;
            }
            string[] allowed = new string[] { "const", "range", "unique", "random", "choice", "template", "pattern", "null", "reference", "datetime", "expression" };
            bool known = false;
            for (int i = 0; i < allowed.Length; i++) if (c.Strategy == allowed[i]) known = true;
            if (!known)
            {
                errors.Add(where + ": unknown strategy '" + c.Strategy + "'.");
                return errors;
            }
            if (!string.IsNullOrEmpty(c.NullRatio))
            {
                decimal ratio;
                if (!decimal.TryParse(c.NullRatio, NumberStyles.Number, CultureInfo.InvariantCulture, out ratio) || ratio < 0m || ratio > 1m)
                    errors.Add(where + ": null_ratio must be between 0 and 1.");
                else if (ratio > 0m && SpecUtil.No(c.IsNullable))
                    errors.Add(where + ": null_ratio > 0 but the column is NOT NULL.");
            }
            bool uniqueKey = SpecUtil.IsPri(c) || SpecUtil.IsUni(c);
            if (c.Strategy == "const") ValidateConst(c, where, rowCount, uniqueKey, errors);
            else if (c.Strategy == "range") ValidateRange(c, where, errors);
            else if (c.Strategy == "unique") ValidateUnique(c, where, rowCount, errors);
            else if (c.Strategy == "choice") ValidateChoice(c, where, uniqueKey, rowCount, errors);
            else if (c.Strategy == "random") ValidateRandom(c, where, uniqueKey, rowCount, errors);
            else if (c.Strategy == "template") ValidateTemplate(c, where, rowCount, errors);
            else if (c.Strategy == "pattern") ValidatePattern(c, where, uniqueKey, rowCount, errors);
            else if (c.Strategy == "null")
            {
                if (SpecUtil.No(c.IsNullable)) errors.Add(where + ": strategy null on a NOT NULL column.");
            }
            else if (c.Strategy == "datetime") ValidateDate(c, where, errors);
            else if (c.Strategy == "reference")
            {
                if (string.IsNullOrEmpty(c.ReferenceTable) || string.IsNullOrEmpty(c.ReferenceColumn))
                    errors.Add(where + ": reference requires reference_table and reference_column.");
                if (uniqueKey) errors.Add(where + ": reference cannot satisfy a PRIMARY or UNIQUE column. Use unique.");
            }
            else if (c.Strategy == "expression")
            {
                string exprError;
                if (!ExpressionSafe(c.Expression, out exprError)) errors.Add(where + ": " + exprError);
            }
            return errors;
        }

        static void ValidateConst(ColumnSpec c, string where, long rowCount, bool uniqueKey, List<string> errors)
        {
            if (c.ConstValue == "$NULL$")
            {
                if (SpecUtil.No(c.IsNullable)) errors.Add(where + ": const $NULL$ on a NOT NULL column.");
                return;
            }
            if (uniqueKey && rowCount > 1) errors.Add(where + ": const cannot be unique across " + rowCount + " rows.");
            string dt = SpecUtil.Dt(c);
            if (SpecUtil.IsInteger(dt) || dt == "decimal" || dt == "numeric" || dt == "year" || dt == "bit")
            {
                BigInteger min, max;
                if (!TryNumericBounds(c, dt, out min, out max)) return;
                BigInteger n;
                if (!BigInteger.TryParse(c.ConstValue ?? "", NumberStyles.Integer, CultureInfo.InvariantCulture, out n))
                {
                    decimal d;
                    if ((dt == "decimal" || dt == "numeric") && decimal.TryParse(c.ConstValue ?? "", NumberStyles.Number, CultureInfo.InvariantCulture, out d))
                        return;
                    errors.Add(where + ": const value is not a number.");
                    return;
                }
                if (n < min || n > max) errors.Add(where + ": const value is outside the column range.");
            }
            CheckCharLength(c, where, (c.ConstValue ?? "").Length, errors);
        }

        static void ValidateRange(ColumnSpec c, string where, List<string> errors)
        {
            string dt = SpecUtil.Dt(c);
            if (!(SpecUtil.IsInteger(dt) || SpecUtil.IsDecimalFamily(dt) || dt == "year" || dt == "bit"))
            {
                errors.Add(where + ": range is only valid for numeric columns.");
                return;
            }
            if (string.IsNullOrEmpty(c.RangeMin) || string.IsNullOrEmpty(c.RangeMax))
            {
                errors.Add(where + ": range_min and range_max are required.");
                return;
            }
            int scale = (dt == "decimal" || dt == "numeric" || dt == "float" || dt == "double" || dt == "real") ? ScaleOf(c, dt) : 0;
            BigInteger a, b;
            if (!TryUnits(c.RangeMin, scale, out a) || !TryUnits(c.RangeMax, scale, out b))
            {
                errors.Add(where + ": range_min or range_max is not a number.");
                return;
            }
            if (a > b) errors.Add(where + ": range_min is greater than range_max.");
            BigInteger tMin, tMax;
            if (TryNumericBounds(c, dt, out tMin, out tMax))
            {
                if (scale == 0)
                {
                    if (a < tMin || b > tMax) errors.Add(where + ": range is outside the column type.");
                }
            }
        }

        static void ValidateUnique(ColumnSpec c, string where, long rowCount, List<string> errors)
        {
            string mode = (c.UniqueMode ?? "").ToLowerInvariant();
            if (mode != "sequence" && mode != "sequence_prefixed" && mode != "uuid")
            {
                errors.Add(where + ": unique_mode must be sequence, sequence_prefixed, or uuid.");
                return;
            }
            BigInteger step;
            if (!BigInteger.TryParse(string.IsNullOrEmpty(c.UniqueStep) ? "1" : c.UniqueStep, NumberStyles.Integer, CultureInfo.InvariantCulture, out step) || step <= 0)
                errors.Add(where + ": unique_step must be a positive integer.");
            if (mode == "uuid")
            {
                int len = SpecUtil.IntOr(c.CharLength, 36);
                string dt = SpecUtil.Dt(c);
                if (SpecUtil.IsString(dt) && SpecUtil.IntOr(c.CharLength, 0) > 0 && len < 36)
                    errors.Add(where + ": uuid needs a string column of at least 36 characters.");
                if (!SpecUtil.IsString(dt)) errors.Add(where + ": uuid mode requires a character column.");
                return;
            }
            BigInteger start;
            string startText = string.IsNullOrEmpty(c.UniqueStart) ? "1" : c.UniqueStart;
            if (!BigInteger.TryParse(startText, NumberStyles.Integer, CultureInfo.InvariantCulture, out start))
            {
                errors.Add(where + ": unique_start is not an integer.");
                return;
            }
            if (mode == "sequence_prefixed" && start < 0) errors.Add(where + ": sequence_prefixed start must be >= 0.");
            if (rowCount > 0 && step > 0)
            {
                BigInteger last = start + (new BigInteger(rowCount - 1) * step);
                string dt = SpecUtil.Dt(c);
                if (mode == "sequence" && (SpecUtil.IsInteger(dt) || dt == "year" || dt == "bit"))
                {
                    BigInteger tMin, tMax;
                    if (TryNumericBounds(c, dt, out tMin, out tMax) && (start < tMin || last > tMax))
                        errors.Add(where + ": unique sequence does not fit in the column.");
                }
                if (mode == "sequence_prefixed")
                {
                    int pad = SpecUtil.IntOr(c.UniquePad, 0);
                    string digits = last.ToString(CultureInfo.InvariantCulture);
                    if (pad > digits.Length) digits = digits.PadLeft(pad, '0');
                    string sample = (c.UniquePrefix ?? "") + digits;
                    CheckCharLength(c, where, sample.Length, errors);
                }
            }
        }

        static void ValidateChoice(ColumnSpec c, string where, bool uniqueKey, long rowCount, List<string> errors)
        {
            string[] items = SpecUtil.SplitPipes(c.ChoiceList);
            if (items.Length == 0) errors.Add(where + ": choice_list is empty.");
            if (uniqueKey && rowCount > 1) errors.Add(where + ": choice cannot guarantee uniqueness. Use unique.");
            if (!string.IsNullOrEmpty(c.EnumValues) && SpecUtil.Dt(c) == "enum")
            {
                string[] allowed = SpecUtil.SplitPipes(c.EnumValues);
                for (int i = 0; i < items.Length; i++)
                {
                    if (items[i] == "$NULL$") continue;
                    bool found = false;
                    for (int j = 0; j < allowed.Length; j++) if (allowed[j] == items[i]) found = true;
                    if (!found) errors.Add(where + ": choice value '" + items[i] + "' is not in the ENUM.");
                }
            }
            for (int i = 0; i < items.Length; i++) CheckCharLength(c, where, items[i].Length, errors);
        }

        static void ValidateRandom(ColumnSpec c, string where, bool uniqueKey, long rowCount, List<string> errors)
        {
            if (uniqueKey && !SpecUtil.Yes(c.UniqueSuffix))
                errors.Add(where + ": random on a PRIMARY or UNIQUE column requires unique_suffix=YES, or use strategy unique.");
            int len = SpecUtil.IntOr(c.StringLength, 0);
            int min = SpecUtil.IntOr(c.StringMinLength, 0);
            int max = SpecUtil.IntOr(c.StringMaxLength, 0);
            if (len <= 0 && !(min > 0 && max >= min)) errors.Add(where + ": string_length is required for random.");
            int worst = len > 0 ? len : max;
            if (SpecUtil.Yes(c.UniqueSuffix) && rowCount > 0)
            {
                BigInteger start = string.IsNullOrEmpty(c.UniqueStart) ? BigInteger.One : BigInteger.Parse(c.UniqueStart, CultureInfo.InvariantCulture);
                BigInteger step = string.IsNullOrEmpty(c.UniqueStep) ? BigInteger.One : BigInteger.Parse(c.UniqueStep, CultureInfo.InvariantCulture);
                BigInteger last = start + (new BigInteger(rowCount - 1) * step);
                int pad = SpecUtil.IntOr(c.UniquePad, last.ToString(CultureInfo.InvariantCulture).Length);
                worst += pad;
            }
            CheckCharLength(c, where, worst, errors);
        }

        static void ValidateTemplate(ColumnSpec c, string where, long rowCount, List<string> errors)
        {
            if (string.IsNullOrEmpty(c.Template))
            {
                errors.Add(where + ": template is empty.");
                return;
            }
            int width = EstimateTemplate(c, rowCount <= 0 ? 0 : rowCount - 1, errors, where);
            if (width >= 0) CheckCharLength(c, where, width, errors);
        }

        static void ValidatePattern(ColumnSpec c, string where, bool uniqueKey, long rowCount, List<string> errors)
        {
            if (string.IsNullOrEmpty(c.Pattern))
            {
                errors.Add(where + ": pattern is empty.");
                return;
            }
            if (uniqueKey && !SpecUtil.Yes(c.UniqueSuffix))
                errors.Add(where + ": pattern on a PRIMARY or UNIQUE column requires unique_suffix=YES, or use strategy unique.");
            int width = 0;
            for (int i = 0; i < c.Pattern.Length; i++)
            {
                if (c.Pattern[i] == '\\' && i + 1 < c.Pattern.Length) { width++; i++; }
                else width++;
            }
            if (SpecUtil.Yes(c.UniqueSuffix) && rowCount > 0)
            {
                BigInteger start = string.IsNullOrEmpty(c.UniqueStart) ? BigInteger.One : BigInteger.Parse(c.UniqueStart, CultureInfo.InvariantCulture);
                BigInteger step = string.IsNullOrEmpty(c.UniqueStep) ? BigInteger.One : BigInteger.Parse(c.UniqueStep, CultureInfo.InvariantCulture);
                string digits = (start + (new BigInteger(rowCount - 1) * step)).ToString(CultureInfo.InvariantCulture);
                int pad = SpecUtil.IntOr(c.UniquePad, digits.Length);
                if (pad > digits.Length) digits = digits.PadLeft(pad, '0');
                width += digits.Length;
            }
            CheckCharLength(c, where, width, errors);
        }

        static void ValidateDate(ColumnSpec c, string where, List<string> errors)
        {
            string dt = SpecUtil.Dt(c);
            if (!(dt == "date" || dt == "datetime" || dt == "timestamp" || dt == "time"))
            {
                errors.Add(where + ": datetime strategy requires a date or time column.");
                return;
            }
            string err;
            DateTime a, b;
            if (!TryParseWhen(c.RangeMin, dt, out a, out err)) errors.Add(where + ": range_min " + err);
            if (!TryParseWhen(c.RangeMax, dt, out b, out err)) errors.Add(where + ": range_max " + err);
            if (errors.Count > 0) return;
            if (a > b) errors.Add(where + ": range_min is after range_max.");
            if (dt == "timestamp")
            {
                DateTime lo = new DateTime(1970, 1, 1, 0, 0, 1);
                DateTime hi = new DateTime(2038, 1, 19, 3, 14, 7);
                if (a < lo || b > hi) errors.Add(where + ": TIMESTAMP values must be between 1970-01-01 00:00:01 and 2038-01-19 03:14:07.");
            }
        }

        static void CheckCharLength(ColumnSpec c, string where, int chars, List<string> errors)
        {
            int max = SpecUtil.IntOr(c.CharLength, 0);
            string dt = SpecUtil.Dt(c);
            if (max > 0 && chars > max && (SpecUtil.IsString(dt) || SpecUtil.IsBinary(dt) || dt == "enum" || dt == "set"))
            {
                if ((c.Overflow ?? "error") == "truncate") return;
                errors.Add(where + ": generated value length " + chars + " exceeds column length " + max + ".");
            }
        }

        static int EstimateTemplate(ColumnSpec c, long rowIndex, List<string> errors, string where)
        {
            string t = c.Template;
            int width = 0;
            for (int i = 0; i < t.Length; i++)
            {
                if (t[i] != '{') { width++; continue; }
                int end = t.IndexOf('}', i);
                if (end < 0)
                {
                    errors.Add(where + ": template has an unclosed '{'.");
                    return -1;
                }
                string token = t.Substring(i + 1, end - i - 1);
                int w = TokenWidth(c, token, rowIndex, errors, where);
                if (w < 0) return -1;
                width += w;
                i = end;
            }
            return width;
        }

        static int TokenWidth(ColumnSpec c, string token, long rowIndex, List<string> errors, string where)
        {
            string kind = token;
            string arg = "";
            int colon = token.IndexOf(':');
            if (colon >= 0)
            {
                kind = token.Substring(0, colon);
                arg = token.Substring(colon + 1);
            }
            if (kind == "seq")
            {
                BigInteger start = string.IsNullOrEmpty(c.UniqueStart) ? BigInteger.One : BigInteger.Parse(c.UniqueStart, CultureInfo.InvariantCulture);
                BigInteger step = string.IsNullOrEmpty(c.UniqueStep) ? BigInteger.One : BigInteger.Parse(c.UniqueStep, CultureInfo.InvariantCulture);
                string digits = (start + (new BigInteger(rowIndex) * step)).ToString(CultureInfo.InvariantCulture);
                int pad = 0;
                if (arg.Length > 0) pad = int.Parse(arg, CultureInfo.InvariantCulture);
                if (pad > digits.Length) return pad;
                return digits.Length;
            }
            if (kind == "uuid") return 36;
            if (kind == "rand")
            {
                int n = arg.Length == 0 ? 1000000 : int.Parse(arg, CultureInfo.InvariantCulture);
                if (n <= 1) return 1;
                return (n - 1).ToString(CultureInfo.InvariantCulture).Length;
            }
            if (kind == "alpha" || kind == "digit" || kind == "hex")
            {
                int n;
                if (!int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) || n < 0)
                {
                    errors.Add(where + ": template token {" + token + "} needs a non-negative length.");
                    return -1;
                }
                return n;
            }
            if (kind == "choice")
            {
                string[] items = SpecUtil.SplitPipes(arg);
                if (items.Length == 0)
                {
                    errors.Add(where + ": template choice is empty.");
                    return -1;
                }
                int m = 0;
                for (int i = 0; i < items.Length; i++) if (items[i].Length > m) m = items[i].Length;
                return m;
            }
            errors.Add(where + ": unknown template token {" + token + "}.");
            return -1;
        }

        public static bool ExpressionSafe(string expression, out string error)
        {
            error = "";
            if (string.IsNullOrEmpty(expression) || expression.Trim().Length == 0)
            {
                error = "expression is empty.";
                return false;
            }
            if (expression.Length > 400)
            {
                error = "expression is longer than 400 characters.";
                return false;
            }
            if (expression.IndexOf(';') >= 0 || expression.IndexOf("--") >= 0 || expression.IndexOf("/*") >= 0 || expression.IndexOf("*/") >= 0)
            {
                error = "expression contains a comment or statement separator.";
                return false;
            }
            int quotes = 0;
            for (int i = 0; i < expression.Length; i++) if (expression[i] == '\'') quotes++;
            if ((quotes % 2) != 0)
            {
                error = "expression has an unbalanced single quote.";
                return false;
            }
            return true;
        }

        public static bool TryParseWhen(string text, string dataType, out DateTime value, out string error)
        {
            value = DateTime.MinValue;
            error = "";
            if (string.IsNullOrEmpty(text))
            {
                error = "is empty.";
                return false;
            }
            string[] formats;
            if (dataType == "time")
            {
                formats = new string[] { "HH:mm:ss", "HH:mm:ss.FFFFFF", "H:mm:ss" };
            }
            else if (dataType == "date")
            {
                formats = new string[] { "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss" };
            }
            else
            {
                formats = new string[] {
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd HH:mm:ss.FFFFFF",
                    "yyyy-MM-ddTHH:mm:ss",
                    "yyyy-MM-dd"
                };
            }
            if (!DateTime.TryParseExact(text.Trim(), formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out value))
            {
                error = "is not a recognized date or time: " + text;
                return false;
            }
            return true;
        }

        static bool TryUnits(string text, int scale, out BigInteger units)
        {
            units = BigInteger.Zero;
            decimal d;
            if (!decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out d)) return false;
            units = ToUnits(d, scale);
            return true;
        }

        public static int ScaleOf(ColumnSpec c, string dt)
        {
            int scale = SpecUtil.IntOr(c.NumScale, -1);
            if (scale >= 0) return scale;
            if (dt == "float" || dt == "double" || dt == "real") return 4;
            return 0;
        }

        public static BigInteger ToUnits(decimal value, int scale)
        {
            if (scale < 0) scale = 0;
            if (scale > 28) throw new InvalidOperationException("scale above 28 is not generated.");
            decimal factor = 1m;
            for (int i = 0; i < scale; i++) factor *= 10m;
            decimal scaled = decimal.Round(value * factor, 0, MidpointRounding.AwayFromZero);
            return new BigInteger(scaled);
        }

        public static string FormatUnits(BigInteger units, int scale)
        {
            bool neg = units < 0;
            BigInteger abs = BigInteger.Abs(units);
            if (scale <= 0) return (neg ? "-" : "") + abs.ToString(CultureInfo.InvariantCulture);
            string digits = abs.ToString(CultureInfo.InvariantCulture);
            if (digits.Length <= scale) digits = digits.PadLeft(scale + 1, '0');
            string whole = digits.Substring(0, digits.Length - scale);
            string frac = digits.Substring(digits.Length - scale);
            return (neg ? "-" : "") + whole + "." + frac;
        }

        static int BitWidth(ColumnSpec c)
        {
            string ct = c.ColumnType ?? "";
            int open = ct.IndexOf('(');
            int close = ct.IndexOf(')');
            int n;
            if (open >= 0 && close > open && int.TryParse(ct.Substring(open + 1, close - open - 1), out n) && n >= 1 && n <= 64)
                return n;
            return 1;
        }

        public static void IntegerBounds(ColumnSpec c, string dt, out BigInteger min, out BigInteger max)
        {
            bool uns = SpecUtil.Yes(c.IsUnsigned) || (c.ColumnType ?? "").ToLowerInvariant().IndexOf("unsigned") >= 0;
            if (dt == "tinyint") { min = uns ? BigInteger.Zero : -128; max = uns ? 255 : 127; return; }
            if (dt == "smallint") { min = uns ? BigInteger.Zero : -32768; max = uns ? 65535 : 32767; return; }
            if (dt == "mediumint") { min = uns ? BigInteger.Zero : -8388608; max = uns ? 16777215 : 8388607; return; }
            if (dt == "int" || dt == "integer")
            {
                min = uns ? BigInteger.Zero : new BigInteger(-2147483648L);
                max = uns ? new BigInteger(4294967295L) : new BigInteger(2147483647L);
                return;
            }
            if (dt == "bigint")
            {
                min = uns ? BigInteger.Zero : BigInteger.Parse("-9223372036854775808");
                max = uns ? BigInteger.Parse("18446744073709551615") : BigInteger.Parse("9223372036854775807");
                return;
            }
            if (dt == "year") { min = 1901; max = 2155; return; }
            if (dt == "bit") { min = BigInteger.Zero; max = (BigInteger.One << BitWidth(c)) - 1; return; }
            min = BigInteger.Zero;
            max = BigInteger.Zero;
        }

        static BigInteger DecimalMaxUnits(ColumnSpec c, string dt, int scale)
        {
            int precision = SpecUtil.IntOr(c.NumPrecision, 10);
            if (precision < scale) precision = scale;
            if (precision > 28) precision = 28;
            string digits = new string('9', Math.Max(1, precision));
            return BigInteger.Parse(digits);
        }

        static bool TryNumericBounds(ColumnSpec c, string dt, out BigInteger min, out BigInteger max)
        {
            min = BigInteger.Zero;
            max = BigInteger.Zero;
            if (SpecUtil.IsInteger(dt) || dt == "year" || dt == "bit")
            {
                IntegerBounds(c, dt, out min, out max);
                return true;
            }
            return false;
        }
    }

    public static class AuroraCsv
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        public static void WriteHeader(TextWriter w, string[] names)
        {
            WriteRow(w, names, null);
        }

        public static void WriteRow(TextWriter w, string[] values, bool[] isNull)
        {
            for (int i = 0; i < values.Length; i++)
            {
                if (i > 0) w.Write(',');
                bool nul = isNull != null && isNull[i];
                WriteField(w, nul ? null : values[i], nul);
            }
            w.Write('\n');
        }

        // Dialect aurora1, shared with LOAD DATA:
        //   FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '\\' LINES TERMINATED BY '\n'
        // NULL is the unquoted token \N. Every other field is quoted and backslash-escaped.
        public static void WriteField(TextWriter w, string value, bool isNull)
        {
            if (isNull || value == null)
            {
                w.Write("\\N");
                return;
            }
            w.Write('"');
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c == '\\' || c == '"') { w.Write('\\'); w.Write(c); }
                else if (c == '\n') w.Write("\\n");
                else if (c == '\r') w.Write("\\r");
                else if (c == '\0') w.Write("\\0");
                else if (c == (char)26) w.Write("\\Z");
                else w.Write(c);
            }
            w.Write('"');
        }

        public sealed class Reader : IDisposable
        {
            StreamReader _r;
            public Reader(string path)
            {
                _r = new StreamReader(path, Utf8, false);
            }
            public void Dispose()
            {
                if (_r != null) _r.Dispose();
            }
            public bool Read(out string[] values, out bool[] isNull)
            {
                values = null;
                isNull = null;
                if (_r.EndOfStream) return false;
                List<string> fields = new List<string>();
                List<bool> nulls = new List<bool>();
                while (true)
                {
                    if (_r.EndOfStream)
                    {
                        if (fields.Count == 0) return false;
                        break;
                    }
                    int peek = _r.Peek();
                    if (peek == '\n' || peek == '\r')
                    {
                        if (peek == '\r') _r.Read();
                        if (_r.Peek() == '\n') _r.Read();
                        if (fields.Count == 0) continue;
                        break;
                    }
                    bool fieldNull;
                    string field = ReadField(out fieldNull);
                    fields.Add(field);
                    nulls.Add(fieldNull);
                    int sep = _r.Peek();
                    if (sep == ',')
                    {
                        _r.Read();
                        if (_r.EndOfStream)
                        {
                            fields.Add("");
                            nulls.Add(false);
                            break;
                        }
                        continue;
                    }
                    if (sep == '\r')
                    {
                        _r.Read();
                        if (_r.Peek() == '\n') _r.Read();
                        break;
                    }
                    if (sep == '\n') { _r.Read(); break; }
                    if (sep < 0) break;
                    throw new InvalidOperationException("Unexpected character after a CSV field.");
                }
                if (fields.Count == 0) return false;
                values = fields.ToArray();
                isNull = nulls.ToArray();
                return true;
            }

            string ReadField(out bool isNull)
            {
                isNull = false;
                int peek = _r.Peek();
                if (peek == '"')
                {
                    _r.Read();
                    StringBuilder sb = new StringBuilder();
                    while (true)
                    {
                        int c = _r.Read();
                        if (c < 0) throw new InvalidOperationException("CSV ended inside a quoted field.");
                        if (c == '\\')
                        {
                            int n = _r.Read();
                            if (n < 0) throw new InvalidOperationException("CSV ended after an escape.");
                            if (n == 'n') sb.Append('\n');
                            else if (n == 'r') sb.Append('\r');
                            else if (n == '0') sb.Append('\0');
                            else if (n == 'Z') sb.Append((char)26);
                            else sb.Append((char)n);
                            continue;
                        }
                        if (c == '"') break;
                        sb.Append((char)c);
                    }
                    return sb.ToString();
                }
                if (peek == '\\')
                {
                    _r.Read();
                    if (_r.Peek() == 'N')
                    {
                        _r.Read();
                        int after = _r.Peek();
                        if (after < 0 || after == ',' || after == '\n' || after == '\r')
                        {
                            isNull = true;
                            return null;
                        }
                        return "\\N" + ReadRaw();
                    }
                    return "\\" + ReadRaw();
                }
                return ReadRaw();
            }

            string ReadRaw()
            {
                StringBuilder sb = new StringBuilder();
                while (true)
                {
                    int p = _r.Peek();
                    if (p < 0 || p == ',' || p == '\n' || p == '\r') break;
                    sb.Append((char)_r.Read());
                }
                return sb.ToString();
            }

            public CsvRecord ReadRecord()
            {
                string[] values;
                bool[] isNull;
                if (!Read(out values, out isNull)) return null;
                CsvRecord record = new CsvRecord();
                record.Values = values;
                record.IsNull = isNull;
                return record;
            }
        }

        public static string[] AppendPart(string partPath, string destPath, bool includeHeader)
        {
            string[] last = null;
            bool append = File.Exists(destPath) && !includeHeader;
            using (Reader reader = new Reader(partPath))
            using (StreamWriter w = new StreamWriter(destPath, append, Utf8, 1 << 20))
            {
                w.NewLine = "\n";
                string[] header;
                bool[] headerNull;
                if (!reader.Read(out header, out headerNull)) return null;
                if (includeHeader) WriteRow(w, header, null);
                string[] values;
                bool[] nulls;
                while (reader.Read(out values, out nulls))
                {
                    WriteRow(w, values, nulls);
                    last = values;
                }
            }
            return last;
        }
    }

    public sealed class CsvRecord
    {
        public string[] Values;
        public bool[] IsNull;
    }

    public static class Generator
    {
        static int Draw(Rng64 rng, int count)
        {
            return (int)rng.NextBounded((ulong)count);
        }

        const string Digits = "0123456789";
        const string Upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const string Lower = "abcdefghijklmnopqrstuvwxyz";
        const string Alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        const string Hex = "0123456789abcdef";

        public static ToolResult WriteCsv(ulong jobSeed, long rowCount, string stringMode, ColumnSpec[] columns, string path)
        {
            ToolResult result = new ToolResult();
            if (columns == null) columns = new ColumnSpec[0];
            if (rowCount < 0)
            {
                result.Errors.Add("row_count is negative.");
                return result;
            }
            string table = columns.Length > 0 ? columns[0].Table : "";
            List<ColumnSpec> outCols = new List<ColumnSpec>();
            for (int i = 0; i < columns.Length; i++)
            {
                ColumnSpec c = columns[i];
                StrategyResolver.Resolve(c, result.Warnings);
                if (SpecUtil.No(c.Include) || c.Strategy == "skip" || c.Strategy == "expression") continue;
                List<string> errs = StrategyResolver.Validate(c, rowCount);
                for (int e = 0; e < errs.Count; e++) result.Errors.Add(errs[e]);
                outCols.Add(c);
            }
            // Expression and skipped columns are still validated when included.
            for (int i = 0; i < columns.Length; i++)
            {
                ColumnSpec c = columns[i];
                if (c.Strategy == "expression" || c.Strategy == "skip" || SpecUtil.No(c.Include))
                {
                    List<string> errs = StrategyResolver.Validate(c, rowCount);
                    for (int e = 0; e < errs.Count; e++) result.Errors.Add(errs[e]);
                }
            }
            if (result.Errors.Count > 0) return result;
            string[] names = new string[outCols.Count];
            for (int i = 0; i < outCols.Count; i++) names[i] = outCols[i].Name;
            result.OutputColumns = names;
            Rng64 rng = Rng64.ForTable(jobSeed, table);
            UTF8Encoding utf8 = new UTF8Encoding(false);
            string dir = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            using (StreamWriter w = new StreamWriter(path, false, utf8, 1 << 20))
            {
                w.NewLine = "\n";
                AuroraCsv.WriteHeader(w, names);
                string[] values = new string[outCols.Count];
                bool[] nulls = new bool[outCols.Count];
                for (long row = 0; row < rowCount; row++)
                {
                    for (int i = 0; i < outCols.Count; i++)
                    {
                        bool isNull;
                        string value = NextValue(outCols[i], row, jobSeed, stringMode, rng, out isNull);
                        values[i] = value;
                        nulls[i] = isNull;
                    }
                    AuroraCsv.WriteRow(w, values, nulls);
                }
            }
            result.Ok = true;
            result.RowCount = rowCount;
            return result;
        }

        public static string NextValue(ColumnSpec c, long row, ulong jobSeed, string stringMode, Rng64 rng, out bool isNull)
        {
            isNull = false;
            string value = "";
            if (c.Strategy == "null")
            {
                isNull = true;
                return null;
            }
            if (c.Strategy == "const")
            {
                if (c.ConstValue == "$NULL$") { isNull = true; return null; }
                value = c.ConstValue ?? "";
                value = CanonicalConst(c, value);
            }
            else if (c.Strategy == "unique") value = UniqueValue(c, row, jobSeed);
            else if (c.Strategy == "range") value = RangeValue(c, rng);
            else if (c.Strategy == "datetime") value = DateValue(c, rng);
            else if (c.Strategy == "choice") value = ChoiceValue(c, rng, out isNull);
            else if (c.Strategy == "random") value = RandomValue(c, row, stringMode, rng);
            else if (c.Strategy == "template") value = TemplateValue(c, row, jobSeed, rng);
            else if (c.Strategy == "pattern") value = PatternValue(c, row, rng);
            else if (c.Strategy == "reference") value = ReferenceValue(c, row, rng, out isNull);
            else throw new InvalidOperationException("Cannot generate strategy " + c.Strategy);
            if (!isNull) ApplyNullRatio(c, rng, ref value, ref isNull);
            if (!isNull && (c.Overflow ?? "error") == "truncate") value = TruncateChars(c, value);
            return isNull ? null : value;
        }

        static void ApplyNullRatio(ColumnSpec c, Rng64 rng, ref string value, ref bool isNull)
        {
            if (string.IsNullOrEmpty(c.NullRatio)) return;
            decimal ratio = decimal.Parse(c.NullRatio, CultureInfo.InvariantCulture);
            if (ratio <= 0m) return;
            ulong roll = rng.Next();
            if (ratio >= 1m) { isNull = true; value = null; return; }
            ulong threshold = RatioThreshold(c.NullRatio);
            if (roll < threshold) { isNull = true; value = null; }
        }

        public static ulong RatioThreshold(string text)
        {
            string t = text.Trim();
            int dot = t.IndexOf('.');
            string whole = dot < 0 ? t : t.Substring(0, dot);
            string frac = dot < 0 ? "" : t.Substring(dot + 1);
            if (whole.Length == 0) whole = "0";
            BigInteger num = BigInteger.Parse(whole + frac, CultureInfo.InvariantCulture);
            int scale = frac.Length;
            if (num == 0) return 0;
            BigInteger den = BigInteger.Pow(new BigInteger(10), scale);
            BigInteger two64 = BigInteger.One << 64;
            BigInteger threshold = (num * two64) / den;
            if (threshold > ulong.MaxValue) return ulong.MaxValue;
            return (ulong)threshold;
        }

        static string CanonicalConst(ColumnSpec c, string value)
        {
            string dt = SpecUtil.Dt(c);
            if (SpecUtil.IsInteger(dt) || dt == "year" || dt == "bit")
            {
                BigInteger n;
                if (BigInteger.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out n))
                    return n.ToString(CultureInfo.InvariantCulture);
            }
            if (dt == "decimal" || dt == "numeric" || dt == "float" || dt == "double" || dt == "real")
            {
                decimal d;
                if (decimal.TryParse(value, NumberStyles.Number, CultureInfo.InvariantCulture, out d))
                    return StrategyResolver.FormatUnits(StrategyResolver.ToUnits(d, StrategyResolver.ScaleOf(c, dt)), StrategyResolver.ScaleOf(c, dt));
            }
            return value;
        }

        static string SequenceDigits(ColumnSpec c, long row)
        {
            BigInteger start = string.IsNullOrEmpty(c.UniqueStart) ? BigInteger.One : BigInteger.Parse(c.UniqueStart, CultureInfo.InvariantCulture);
            BigInteger step = string.IsNullOrEmpty(c.UniqueStep) ? BigInteger.One : BigInteger.Parse(c.UniqueStep, CultureInfo.InvariantCulture);
            BigInteger seq = start + (new BigInteger(row) * step);
            string digits = seq.ToString(CultureInfo.InvariantCulture);
            int pad = SpecUtil.IntOr(c.UniquePad, 0);
            if (pad > digits.Length && seq >= 0) digits = digits.PadLeft(pad, '0');
            return digits;
        }

        static string UniqueValue(ColumnSpec c, long row, ulong jobSeed)
        {
            string mode = (c.UniqueMode ?? "sequence").ToLowerInvariant();
            if (mode == "uuid") return Uuid(jobSeed, c.Table, c.Name, row);
            if (mode == "sequence_prefixed") return (c.UniquePrefix ?? "") + SequenceDigits(c, row);
            return SequenceDigits(c, row);
        }

        public static string Uuid(ulong jobSeed, string table, string column, long row)
        {
            ulong salt = Rng64.Mix(jobSeed, (table ?? "") + "\n" + (column ?? ""));
            ulong n = (ulong)row + 1UL;
            char[] h = (ToHex16(salt) + ToHex16(n)).ToCharArray();
            h[12] = '4';
            int variant = Convert.ToInt32(h[16].ToString(), 16);
            variant = (variant & 0x3) | 0x8;
            h[16] = "0123456789abcdef"[variant];
            return new string(h, 0, 8) + "-" + new string(h, 8, 4) + "-" + new string(h, 12, 4) + "-" + new string(h, 16, 4) + "-" + new string(h, 20, 12);
        }

        static string ToHex16(ulong v)
        {
            return v.ToString("x16", CultureInfo.InvariantCulture);
        }

        static string RangeValue(ColumnSpec c, Rng64 rng)
        {
            string dt = SpecUtil.Dt(c);
            int scale = (SpecUtil.IsDecimalFamily(dt) && dt != "bit") ? StrategyResolver.ScaleOf(c, dt) : 0;
            if (SpecUtil.IsInteger(dt) || dt == "year" || dt == "bit") scale = 0;
            BigInteger a = StrategyResolver.ToUnits(decimal.Parse(c.RangeMin, CultureInfo.InvariantCulture), scale);
            BigInteger b = StrategyResolver.ToUnits(decimal.Parse(c.RangeMax, CultureInfo.InvariantCulture), scale);
            BigInteger span = (b - a) + 1;
            BigInteger picked = a + rng.NextBoundedBig(span);
            if (scale == 0) return picked.ToString(CultureInfo.InvariantCulture);
            return StrategyResolver.FormatUnits(picked, scale);
        }

        static string DateValue(ColumnSpec c, Rng64 rng)
        {
            string dt = SpecUtil.Dt(c);
            string err;
            DateTime a, b;
            StrategyResolver.TryParseWhen(c.RangeMin, dt, out a, out err);
            StrategyResolver.TryParseWhen(c.RangeMax, dt, out b, out err);
            int precision = SpecUtil.IntOr(c.DatetimePrecision, 0);
            if (precision < 0) precision = 0;
            if (precision > 6) precision = 6;
            long step = TimeSpan.TicksPerSecond;
            for (int i = 0; i < precision; i++) step /= 10L;
            if (step < 10L) step = 10L;
            long start = CeilTicks(a.Ticks, step);
            long end = FloorTicks(b.Ticks, step);
            if (end < start) end = start;
            ulong steps = (ulong)((end - start) / step) + 1UL;
            ulong add = rng.NextBounded(steps);
            DateTime value = new DateTime(start + (long)add * step, DateTimeKind.Unspecified);
            return FormatWhen(value, dt, precision);
        }

        static long FloorTicks(long ticks, long step)
        {
            long rem = ticks % step;
            if (rem < 0) rem += step;
            return ticks - rem;
        }

        static long CeilTicks(long ticks, long step)
        {
            long floored = FloorTicks(ticks, step);
            if (floored == ticks) return ticks;
            return floored + step;
        }

        static string FormatWhen(DateTime value, string dt, int precision)
        {
            if (dt == "date") return value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (dt == "time")
            {
                string fmt = precision > 0 ? "HH:mm:ss." + new string('f', precision) : "HH:mm:ss";
                return value.ToString(fmt, CultureInfo.InvariantCulture);
            }
            if (dt == "year") return value.ToString("yyyy", CultureInfo.InvariantCulture);
            string full = precision > 0 ? "yyyy-MM-dd HH:mm:ss." + new string('f', precision) : "yyyy-MM-dd HH:mm:ss";
            return value.ToString(full, CultureInfo.InvariantCulture);
        }

        static string ChoiceValue(ColumnSpec c, Rng64 rng, out bool isNull)
        {
            isNull = false;
            string[] items = SpecUtil.SplitPipes(c.ChoiceList);
            string picked = items[Draw(rng, items.Length)];
            if (picked == "$NULL$") { isNull = true; return null; }
            return picked;
        }

        static string RandomValue(ColumnSpec c, long row, string stringMode, Rng64 rng)
        {
            int len = SpecUtil.IntOr(c.StringLength, 0);
            if (len <= 0)
            {
                int min = SpecUtil.IntOr(c.StringMinLength, 1);
                int max = SpecUtil.IntOr(c.StringMaxLength, min);
                len = min + (int)rng.NextBounded((ulong)(max - min + 1));
            }
            StringBuilder sb = new StringBuilder(len);
            bool unicode = string.Equals(stringMode, "unicode", StringComparison.OrdinalIgnoreCase);
            for (int i = 0; i < len; i++)
            {
                if (unicode)
                {
                    int cp = 0x3042 + (int)rng.NextBounded((ulong)(0x3063 - 0x3042 + 1));
                    sb.Append((char)cp);
                }
                else sb.Append(Alnum[Draw(rng, Alnum.Length)]);
            }
            if (SpecUtil.Yes(c.UniqueSuffix)) sb.Append(SequenceDigits(c, row));
            return sb.ToString();
        }

        static string TemplateValue(ColumnSpec c, long row, ulong jobSeed, Rng64 rng)
        {
            string t = c.Template ?? "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < t.Length; i++)
            {
                if (t[i] != '{') { sb.Append(t[i]); continue; }
                int end = t.IndexOf('}', i);
                string token = t.Substring(i + 1, end - i - 1);
                sb.Append(EvalToken(c, token, row, jobSeed, rng));
                i = end;
            }
            return sb.ToString();
        }

        static string EvalToken(ColumnSpec c, string token, long row, ulong jobSeed, Rng64 rng)
        {
            string kind = token;
            string arg = "";
            int colon = token.IndexOf(':');
            if (colon >= 0)
            {
                kind = token.Substring(0, colon);
                arg = token.Substring(colon + 1);
            }
            if (kind == "seq")
            {
                BigInteger start = string.IsNullOrEmpty(c.UniqueStart) ? BigInteger.One : BigInteger.Parse(c.UniqueStart, CultureInfo.InvariantCulture);
                BigInteger step = string.IsNullOrEmpty(c.UniqueStep) ? BigInteger.One : BigInteger.Parse(c.UniqueStep, CultureInfo.InvariantCulture);
                string digits = (start + (new BigInteger(row) * step)).ToString(CultureInfo.InvariantCulture);
                int pad = 0;
                if (arg.Length > 0) pad = int.Parse(arg, CultureInfo.InvariantCulture);
                if (pad > digits.Length && !digits.StartsWith("-")) digits = digits.PadLeft(pad, '0');
                return digits;
            }
            if (kind == "uuid") return Uuid(jobSeed, c.Table, c.Name, row);
            if (kind == "rand")
            {
                int n = arg.Length == 0 ? 1000000 : int.Parse(arg, CultureInfo.InvariantCulture);
                if (n <= 0) n = 1;
                return rng.NextBounded((ulong)n).ToString(CultureInfo.InvariantCulture);
            }
            if (kind == "alpha" || kind == "digit" || kind == "hex")
            {
                int n = int.Parse(arg, CultureInfo.InvariantCulture);
                string alphabet = kind == "alpha" ? (Upper + Lower) : kind == "digit" ? Digits : Hex;
                StringBuilder sb = new StringBuilder(n);
                for (int i = 0; i < n; i++) sb.Append(alphabet[Draw(rng, alphabet.Length)]);
                return sb.ToString();
            }
            if (kind == "choice")
            {
                string[] items = SpecUtil.SplitPipes(arg);
                return items[Draw(rng, items.Length)];
            }
            throw new InvalidOperationException("Bad template token " + token);
        }

        static string PatternValue(ColumnSpec c, long row, Rng64 rng)
        {
            string p = c.Pattern ?? "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < p.Length; i++)
            {
                char ch = p[i];
                if (ch == '\\' && i + 1 < p.Length) { sb.Append(p[i + 1]); i++; continue; }
                if (ch == '#') sb.Append(Digits[Draw(rng, 10)]);
                else if (ch == 'A') sb.Append(Upper[Draw(rng, 26)]);
                else if (ch == 'a') sb.Append(Lower[Draw(rng, 26)]);
                else if (ch == 'X') sb.Append(Alnum[Draw(rng, Alnum.Length)]);
                else sb.Append(ch);
            }
            if (SpecUtil.Yes(c.UniqueSuffix)) sb.Append(SequenceDigits(c, row));
            return sb.ToString();
        }

        static string ReferenceValue(ColumnSpec c, long row, Rng64 rng, out bool isNull)
        {
            isNull = false;
            string mode = (c.ReferenceMode ?? "").ToLowerInvariant();
            if (mode.Length == 0)
            {
                if (c.ReferenceValues != null && c.ReferenceValues.Length > 0) mode = "list";
                else if (!string.IsNullOrEmpty(c.ReferenceStart) && !string.IsNullOrEmpty(c.ReferenceCount)) mode = "virtual";
                else mode = "prior";
            }
            if (mode == "list")
            {
                string[] values = c.ReferenceValues ?? new string[0];
                if (values.Length == 0) throw new InvalidOperationException(c.Table + "." + c.Name + ": reference list is empty.");
                return values[Draw(rng, values.Length)];
            }
            if (mode == "virtual" || mode == "prior")
            {
                BigInteger start = BigInteger.Parse(string.IsNullOrEmpty(c.ReferenceStart) ? "1" : c.ReferenceStart, CultureInfo.InvariantCulture);
                BigInteger step = BigInteger.Parse(string.IsNullOrEmpty(c.ReferenceStep) ? "1" : c.ReferenceStep, CultureInfo.InvariantCulture);
                if (mode == "prior")
                {
                    if (row == 0)
                    {
                        if (SpecUtil.Yes(c.IsNullable)) { isNull = true; return null; }
                        return start.ToString(CultureInfo.InvariantCulture);
                    }
                    ulong pick = rng.NextBounded((ulong)row + 1UL);
                    return (start + (new BigInteger(pick) * step)).ToString(CultureInfo.InvariantCulture);
                }
                ulong count = ulong.Parse(c.ReferenceCount, CultureInfo.InvariantCulture);
                if (count == 0) throw new InvalidOperationException(c.Table + "." + c.Name + ": reference count is 0.");
                ulong idx = rng.NextBounded(count);
                return (start + (new BigInteger(idx) * step)).ToString(CultureInfo.InvariantCulture);
            }
            throw new InvalidOperationException("Unknown reference_mode " + mode);
        }

        static string TruncateChars(ColumnSpec c, string value)
        {
            if (value == null) return null;
            int max = SpecUtil.IntOr(c.CharLength, 0);
            if (max > 0 && value.Length > max) return value.Substring(0, max);
            return value;
        }

        static string SqlValue(ColumnSpec column, string value, bool isNull)
        {
            if (isNull || value == null) return "NULL";
            string transport = column.Transport ?? "";
            if (transport == "hex") return "UNHEX(" + Sql.Literal(value, false, "char") + ")";
            if (transport == "wkb") return "ST_GeomFromWKB(UNHEX(" + Sql.Literal(value, false, "char") + "))";
            return Sql.Literal(value, false, column.DataType);
        }

        public static void WriteInsertFile(string csvPath, string sqlPath, string database, string table, ColumnSpec[] ordered, int batchSize, int maxPacketBytes, bool disableFk, bool relaxUnique, string timeZone)
        {
            if (batchSize < 1) batchSize = 1;
            if (maxPacketBytes < 4096) maxPacketBytes = 4096;
            List<ColumnSpec> cols = new List<ColumnSpec>();
            for (int i = 0; i < ordered.Length; i++)
            {
                ColumnSpec c = ordered[i];
                if (SpecUtil.No(c.Include) || c.Strategy == "skip") continue;
                cols.Add(c);
            }
            StringBuilder colList = new StringBuilder();
            for (int i = 0; i < cols.Count; i++)
            {
                if (i > 0) colList.Append(',');
                colList.Append(Sql.QuoteIdent(cols[i].Name));
            }
            string insertHead = "INSERT INTO " + Sql.QuoteQualified(database, table) + " (" + colList + ") VALUES ";
            UTF8Encoding utf8 = new UTF8Encoding(false);
            using (AuroraCsv.Reader reader = new AuroraCsv.Reader(csvPath))
            using (StreamWriter w = new StreamWriter(sqlPath, false, utf8, 1 << 20))
            {
                w.NewLine = "\n";
                string[] header;
                bool[] headerNull;
                if (!reader.Read(out header, out headerNull)) throw new InvalidOperationException("CSV has no header: " + csvPath);
                Dictionary<string, int> headerIndex = new Dictionary<string, int>(StringComparer.Ordinal);
                for (int h = 0; h < header.Length; h++)
                {
                    if (header[h] == null) throw new InvalidOperationException("CSV header contains NULL.");
                    if (headerIndex.ContainsKey(header[h])) throw new InvalidOperationException("Duplicate CSV column " + header[h]);
                    headerIndex[header[h]] = h;
                }
                int[] csvIndex = new int[cols.Count];
                for (int i = 0; i < cols.Count; i++)
                {
                    if (cols[i].Strategy == "expression") { csvIndex[i] = -1; continue; }
                    int ix;
                    if (!headerIndex.TryGetValue(cols[i].Name, out ix))
                        throw new InvalidOperationException("CSV is missing column " + cols[i].Name + ".");
                    csvIndex[i] = ix;
                }
                w.Write("SET NAMES utf8mb4;\n");
                w.Write("SET SESSION time_zone = '" + (string.IsNullOrEmpty(timeZone) ? "+00:00" : timeZone.Replace("'", "''")) + "';\n");
                w.Write("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_BACKSLASH_ESCAPES';\n");
                if (disableFk) w.Write("SET SESSION foreign_key_checks = 0;\n");
                if (relaxUnique) w.Write("SET SESSION unique_checks = 0;\n");
                w.Write("SET SESSION autocommit = 0;\n");
                StringBuilder batch = new StringBuilder();
                int rows = 0;
                string[] values;
                bool[] nulls;
                while (reader.Read(out values, out nulls))
                {
                    StringBuilder tuple = new StringBuilder();
                    tuple.Append('(');
                    for (int i = 0; i < cols.Count; i++)
                    {
                        if (i > 0) tuple.Append(',');
                        if (cols[i].Strategy == "expression") tuple.Append(cols[i].Expression);
                        else
                        {
                            int ix = csvIndex[i];
                            tuple.Append(SqlValue(cols[i], values[ix], nulls[ix]));
                        }
                    }
                    tuple.Append(')');
                    if (rows > 0 && (rows >= batchSize || batch.Length + tuple.Length + insertHead.Length + 2 > maxPacketBytes))
                    {
                        w.Write(insertHead);
                        w.Write(batch.ToString());
                        w.Write(";\nCOMMIT;\n");
                        batch.Length = 0;
                        rows = 0;
                    }
                    if (rows > 0) batch.Append(',');
                    batch.Append(tuple.ToString());
                    rows++;
                }
                if (rows > 0)
                {
                    w.Write(insertHead);
                    w.Write(batch.ToString());
                    w.Write(";\nCOMMIT;\n");
                }
                if (relaxUnique) w.Write("SET SESSION unique_checks = 1;\n");
                if (disableFk) w.Write("SET SESSION foreign_key_checks = 1;\n");
                w.Write("COMMIT;\n");
            }
        }
    }

    public static class HexTable
    {
        public static string Utf8ToHex(string text)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(text ?? "");
            return BytesToHex(bytes);
        }

        public static string HexToUtf8(string hex)
        {
            byte[] bytes = HexToBytes(hex);
            return Encoding.UTF8.GetString(bytes);
        }

        public static string BytesToHex(byte[] bytes)
        {
            char[] c = new char[bytes.Length * 2];
            const string hex = "0123456789ABCDEF";
            for (int i = 0; i < bytes.Length; i++)
            {
                c[i * 2] = hex[bytes[i] >> 4];
                c[i * 2 + 1] = hex[bytes[i] & 0xF];
            }
            return new string(c);
        }

        public static byte[] HexToBytes(string hex)
        {
            if (string.IsNullOrEmpty(hex)) return new byte[0];
            if ((hex.Length % 2) != 0) throw new InvalidOperationException("Hex length is odd.");
            byte[] bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
            {
                int hi = HexNibble(hex[i * 2]);
                int lo = HexNibble(hex[i * 2 + 1]);
                bytes[i] = (byte)((hi << 4) | lo);
            }
            return bytes;
        }

        static int HexNibble(char c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            throw new InvalidOperationException("Invalid hex character.");
        }

        // transports: text, hex, wkb, number. TSV is mysql --batch --raw.
        public static long ConvertTsv(string tsvPath, string csvPath, string[] columnNames, string[] transports)
        {
            UTF8Encoding utf8 = new UTF8Encoding(false);
            long rows = 0;
            using (FileStream input = File.OpenRead(tsvPath))
            using (StreamWriter w = new StreamWriter(csvPath, false, utf8, 1 << 20))
            {
                w.NewLine = "\n";
                AuroraCsv.WriteHeader(w, columnNames);
                byte[] line = ReadLine(input);
                if (line == null) throw new InvalidOperationException("Export output is empty.");
                while ((line = ReadLine(input)) != null)
                {
                    if (line.Length == 0) continue;
                    string[] fields = SplitTabs(utf8.GetString(line));
                    if (fields.Length != transports.Length)
                        throw new InvalidOperationException("Export column count does not match the schema.");
                    string[] values = new string[fields.Length];
                    bool[] nulls = new bool[fields.Length];
                    for (int i = 0; i < fields.Length; i++)
                    {
                        if (fields[i] == "\\N" || fields[i] == "NULL") { nulls[i] = true; continue; }
                        string kind = transports[i];
                        if (kind == "text") values[i] = HexToUtf8(fields[i]);
                        else values[i] = fields[i];
                    }
                    AuroraCsv.WriteRow(w, values, nulls);
                    rows++;
                }
            }
            return rows;
        }

        static string[] SplitTabs(string line)
        {
            return line.Split('\t');
        }

        static byte[] ReadLine(FileStream input)
        {
            MemoryStream ms = new MemoryStream();
            int b;
            bool any = false;
            while ((b = input.ReadByte()) >= 0)
            {
                any = true;
                if (b == '\n') break;
                if (b != '\r') ms.WriteByte((byte)b);
            }
            if (!any) return null;
            return ms.ToArray();
        }
    }
}

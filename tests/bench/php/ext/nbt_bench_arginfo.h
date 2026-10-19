/* This is a generated file, edit the .stub.php file instead.
 * Stub hash: 3f4863504ae98cc8e5ff4867e6827060e79e1f13 */

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_nbt_bench_decode_int_array, 0, 2, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, bytes, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, encoding, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_nbt_bench_encode_int_array, 0, 2, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, values, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, encoding, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_nbt_bench_scan, 0, 2, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, bytes, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, encoding, IS_LONG, 0)
ZEND_END_ARG_INFO()

#define arginfo_nbt_bench_decode arginfo_nbt_bench_decode_int_array

ZEND_FUNCTION(nbt_bench_decode_int_array);
ZEND_FUNCTION(nbt_bench_encode_int_array);
ZEND_FUNCTION(nbt_bench_scan);
ZEND_FUNCTION(nbt_bench_decode);

static const zend_function_entry ext_functions[] = {
	ZEND_FE(nbt_bench_decode_int_array, arginfo_nbt_bench_decode_int_array)
	ZEND_FE(nbt_bench_encode_int_array, arginfo_nbt_bench_encode_int_array)
	ZEND_FE(nbt_bench_scan, arginfo_nbt_bench_scan)
	ZEND_FE(nbt_bench_decode, arginfo_nbt_bench_decode)
	ZEND_FE_END
};

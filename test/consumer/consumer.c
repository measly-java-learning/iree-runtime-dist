// Consumer acceptance test. Proves, in one run: the CMake package resolves, the
// link surface is complete, compile definitions propagate, the shipped add.vmfb
// loads against this runtime (compiler/runtime ABI pairing), and the requested
// HAL driver works.
//
// Usage: consumer <add.vmfb> <driver-name>
#include <stdio.h>
#include <string.h>

#include "iree/runtime/api.h"

#define CHECK(expr)                                              \
  do {                                                            \
    iree_status_t _s = (expr);                                    \
    if (!iree_status_is_ok(_s)) {                                 \
      fprintf(stderr, "FAIL at %s:%d\n", __FILE__, __LINE__);     \
      iree_status_fprint(stderr, _s);                              \
      iree_status_free(_s);                                        \
      return 1;                                                    \
    }                                                              \
  } while (0)

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: consumer <add.vmfb> <driver-name>\n");
    return 2;
  }
  const char* module_path = argv[1];
  const char* driver_name = argv[2];

  // iree_allocator_system() is only declared when IREE_ALLOCATOR_SYSTEM_CTL is
  // defined. If the export set failed to propagate that define, this will not
  // compile -- which is the point.
  iree_allocator_t host_allocator = iree_allocator_system();

  iree_runtime_instance_options_t instance_options;
  iree_runtime_instance_options_initialize(&instance_options);
  iree_runtime_instance_options_use_all_available_drivers(&instance_options);

  iree_runtime_instance_t* instance = NULL;
  CHECK(iree_runtime_instance_create(&instance_options, host_allocator, &instance));

  iree_hal_device_t* device = NULL;
  // NOTE: this takes a driver_name (e.g. "local-sync", "local-task"), not a
  // URI. Driver registration does an exact string compare against the
  // registered name; "local-sync://" would fail to resolve.
  CHECK(iree_runtime_instance_try_create_default_device(
      instance, iree_make_cstring_view(driver_name), &device));

  iree_runtime_session_options_t session_options;
  iree_runtime_session_options_initialize(&session_options);
  iree_runtime_session_t* session = NULL;
  CHECK(iree_runtime_session_create_with_device(
      instance, &session_options, device,
      iree_runtime_instance_host_allocator(instance), &session));

  // The load step is where a compiler/runtime VM import signature mismatch
  // surfaces. A shipped, paired add.vmfb makes this pass by construction.
  CHECK(iree_runtime_session_append_bytecode_module_from_file(session, module_path));

  iree_runtime_call_t call;
  CHECK(iree_runtime_call_initialize_by_name(
      session, iree_make_cstring_view("module.add"), &call));

  const float lhs_data[4] = {1.0f, 2.0f, 3.0f, 4.0f};
  const float rhs_data[4] = {10.0f, 20.0f, 30.0f, 40.0f};
  const iree_hal_dim_t shape[1] = {4};

  iree_hal_buffer_view_t* lhs = NULL;
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, iree_hal_device_allocator(device), 1, shape,
      IREE_HAL_ELEMENT_TYPE_FLOAT_32, IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
      (iree_hal_buffer_params_t){
          .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL,
          .usage = IREE_HAL_BUFFER_USAGE_DEFAULT,
      },
      iree_make_const_byte_span(lhs_data, sizeof(lhs_data)), &lhs));
  CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, lhs));
  iree_hal_buffer_view_release(lhs);

  iree_hal_buffer_view_t* rhs = NULL;
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, iree_hal_device_allocator(device), 1, shape,
      IREE_HAL_ELEMENT_TYPE_FLOAT_32, IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
      (iree_hal_buffer_params_t){
          .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL,
          .usage = IREE_HAL_BUFFER_USAGE_DEFAULT,
      },
      iree_make_const_byte_span(rhs_data, sizeof(rhs_data)), &rhs));
  CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, rhs));
  iree_hal_buffer_view_release(rhs);

  CHECK(iree_runtime_call_invoke(&call, /*flags=*/0));

  iree_hal_buffer_view_t* result = NULL;
  CHECK(iree_runtime_call_outputs_pop_front_buffer_view(&call, &result));

  float out[4] = {0};
  CHECK(iree_hal_device_transfer_d2h(
      device, iree_hal_buffer_view_buffer(result), 0, out, sizeof(out),
      IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout()));

  const float expected[4] = {11.0f, 22.0f, 33.0f, 44.0f};
  int rc = 0;
  for (int i = 0; i < 4; ++i) {
    if (out[i] != expected[i]) {
      fprintf(stderr, "FAIL: out[%d] = %f, expected %f\n", i, out[i], expected[i]);
      rc = 1;
    }
  }
  if (rc == 0) {
    printf("ok: add.vmfb ran on %s and produced [%.0f, %.0f, %.0f, %.0f]\n",
           driver_name, out[0], out[1], out[2], out[3]);
  }

  iree_hal_buffer_view_release(result);
  iree_runtime_call_deinitialize(&call);
  iree_runtime_session_release(session);
  iree_hal_device_release(device);
  iree_runtime_instance_release(instance);
  return rc;
}

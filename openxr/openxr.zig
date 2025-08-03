const std = @import("std");

pub const c = @import("c");
pub const SystemId = c.XrSystemId;
pub const Time = c.XrTime;

pub const Result = enum(c.XrResult) {
    success = 0,
    timeout_expired = 1,
    session_loss_pending = 3,
    event_unavailable = 4,
    space_bounds_unavailable = 7,
    session_not_focused = 8,
    frame_discarded = 9,
    error_validation_failure = -1,
    error_runtime_failure = -2,
    error_out_of_memory = -3,
    error_api_version_unsupported = -4,
    error_initialization_failed = -6,
    error_function_unsupported = -7,
    error_feature_unsupported = -8,
    error_extension_not_present = -9,
    error_limit_reached = -10,
    error_size_insufficient = -11,
    error_handle_invalid = -12,
    error_instance_lost = -13,
    error_session_running = -14,
    error_session_not_running = -16,
    error_session_lost = -17,
    error_system_invalid = -18,
    error_path_invalid = -19,
    error_path_count_exceeded = -20,
    error_path_format_invalid = -21,
    error_path_unsupported = -22,
    error_layer_invalid = -23,
    error_layer_limit_exceeded = -24,
    error_swapchain_rect_invalid = -25,
    error_swapchain_format_unsupported = -26,
    error_action_type_mismatch = -27,
    error_session_not_ready = -28,
    error_session_not_stopping = -29,
    error_time_invalid = -30,
    error_reference_space_unsupported = -31,
    error_file_access_error = -32,
    error_file_contents_invalid = -33,
    error_form_factor_unsupported = -34,
    error_form_factor_unavailable = -35,
    error_api_layer_not_present = -36,
    error_call_order_invalid = -37,
    error_graphics_device_invalid = -38,
    error_pose_invalid = -39,
    error_index_out_of_range = -40,
    error_view_configuration_type_unsupported = -41,
    error_environment_blend_mode_unsupported = -42,
    error_name_duplicated = -44,
    error_name_invalid = -45,
    error_actionset_not_attached = -46,
    error_actionsets_already_attached = -47,
    error_localized_name_duplicated = -48,
    error_localized_name_invalid = -49,
    error_graphics_requirements_call_missing = -50,
    error_runtime_unavailable = -51,
    error_extension_dependency_not_enabled = -1000710001,
    error_permission_insufficient = -1000710000,
    error_android_thread_settings_id_invalid_khr = -1000003000,
    error_android_thread_settings_failure_khr = -1000003001,
    error_create_spatial_anchor_failed_msft = -1000039001,
    error_secondary_view_configuration_type_not_enabled_msft = -1000053000,
    error_controller_model_key_invalid_msft = -1000055000,
    error_reprojection_mode_unsupported_msft = -1000066000,
    error_compute_new_scene_not_completed_msft = -1000097000,
    error_scene_component_id_invalid_msft = -1000097001,
    error_scene_component_type_mismatch_msft = -1000097002,
    error_scene_mesh_buffer_id_invalid_msft = -1000097003,
    error_scene_compute_feature_incompatible_msft = -1000097004,
    error_scene_compute_consistency_mismatch_msft = -1000097005,
    error_display_refresh_rate_unsupported_fb = -1000101000,
    error_color_space_unsupported_fb = -1000108000,
    error_space_component_not_supported_fb = -1000113000,
    error_space_component_not_enabled_fb = -1000113001,
    error_space_component_status_pending_fb = -1000113002,
    error_space_component_status_already_set_fb = -1000113003,
    error_unexpected_state_passthrough_fb = -1000118000,
    error_feature_already_created_passthrough_fb = -1000118001,
    error_feature_required_passthrough_fb = -1000118002,
    error_not_permitted_passthrough_fb = -1000118003,
    error_insufficient_resources_passthrough_fb = -1000118004,
    error_unknown_passthrough_fb = -1000118050,
    error_render_model_key_invalid_fb = -1000119000,
    render_model_unavailable_fb = 1000119020,
    error_marker_not_tracked_varjo = -1000124000,
    error_marker_id_invalid_varjo = -1000124001,
    error_marker_detector_permission_denied_ml = -1000138000,
    error_marker_detector_locate_failed_ml = -1000138001,
    error_marker_detector_invalid_data_query_ml = -1000138002,
    error_marker_detector_invalid_create_info_ml = -1000138003,
    error_marker_invalid_ml = -1000138004,
    error_localization_map_incompatible_ml = -1000139000,
    error_localization_map_unavailable_ml = -1000139001,
    error_localization_map_fail_ml = -1000139002,
    error_localization_map_import_export_permission_denied_ml = -1000139003,
    error_localization_map_permission_denied_ml = -1000139004,
    error_localization_map_already_exists_ml = -1000139005,
    error_localization_map_cannot_export_cloud_map_ml = -1000139006,
    error_spatial_anchors_permission_denied_ml = -1000140000,
    error_spatial_anchors_not_localized_ml = -1000140001,
    error_spatial_anchors_out_of_map_bounds_ml = -1000140002,
    error_spatial_anchors_space_not_locatable_ml = -1000140003,
    error_spatial_anchors_anchor_not_found_ml = -1000141000,
    error_spatial_anchor_name_not_found_msft = -1000142001,
    error_spatial_anchor_name_invalid_msft = -1000142002,
    scene_marker_data_not_string_msft = 1000147000,
    error_space_mapping_insufficient_fb = -1000169000,
    error_space_localization_failed_fb = -1000169001,
    error_space_network_timeout_fb = -1000169002,
    error_space_network_request_failed_fb = -1000169003,
    error_space_cloud_storage_disabled_fb = -1000169004,
    error_passthrough_color_lut_buffer_size_mismatch_meta = -1000266000,
    environment_depth_not_available_meta = 1000291000,
    error_hint_already_set_qcom = -1000306000,
    error_not_an_anchor_htc = -1000319000,
    error_spatial_entity_id_invalid_bd = -1000389000,
    error_spatial_sensing_service_unavailable_bd = -1000389001,
    error_anchor_not_supported_for_entity_bd = -1000389002,
    error_spatial_anchor_not_found_bd = -1000390000,
    error_spatial_anchor_sharing_network_timeout_bd = -1000391000,
    error_spatial_anchor_sharing_authentication_failure_bd = -1000391001,
    error_spatial_anchor_sharing_network_failure_bd = -1000391002,
    error_spatial_anchor_sharing_localization_fail_bd = -1000391003,
    error_spatial_anchor_sharing_map_insufficient_bd = -1000391004,
    error_scene_capture_failure_bd = -1000392000,
    error_space_not_locatable_ext = -1000429000,
    error_plane_detection_permission_denied_ext = -1000429001,
    error_future_pending_ext = -1000469001,
    error_future_invalid_ext = -1000469002,
    error_system_notification_permission_denied_ml = -1000473000,
    error_system_notification_incompatible_sku_ml = -1000473001,
    error_world_mesh_detector_permission_denied_ml = -1000474000,
    error_world_mesh_detector_space_not_locatable_ml = -1000474001,
    error_facial_expression_permission_denied_ml = 1000482000,
    error_colocation_discovery_network_failed_meta = -1000571001,
    error_colocation_discovery_no_discovery_method_meta = -1000571002,
    colocation_discovery_already_advertising_meta = 1000571003,
    colocation_discovery_already_discovering_meta = 1000571004,
    error_space_group_not_found_meta = -1000572002,
};

pub const ResultError = @Type(.{ .error_set = blk: {
    const result_values = @typeInfo(Result).@"enum".fields;

    var errors: [result_values.len]std.builtin.Type.Error = undefined;

    for (&errors, result_values) |*err, result| {
        err.* = .{ .name = result.name };
    }

    break :blk &errors;
} });

pub fn convertResult(xr_result: c.XrResult) ResultError!void {
    const result: Result = @enumFromInt(xr_result);

    if (result == .success) {
        return;
    }

    return switch (result) {
        inline else => |error_result| @field(ResultError, @tagName(error_result)),
    };
}

pub const StructureType = enum(c.XrStructureType) {
    unknown = 0,
    api_layer_properties = 1,
    extension_properties = 2,
    instance_create_info = 3,
    system_get_info = 4,
    system_properties = 5,
    view_locate_info = 6,
    view = 7,
    session_create_info = 8,
    swapchain_create_info = 9,
    session_begin_info = 10,
    view_state = 11,
    frame_end_info = 12,
    haptic_vibration = 13,
    event_data_buffer = 16,
    event_data_instance_loss_pending = 17,
    event_data_session_state_changed = 18,
    action_state_boolean = 23,
    action_state_float = 24,
    action_state_vector2f = 25,
    action_state_pose = 27,
    action_set_create_info = 28,
    action_create_info = 29,
    instance_properties = 32,
    frame_wait_info = 33,
    composition_layer_projection = 35,
    composition_layer_quad = 36,
    reference_space_create_info = 37,
    action_space_create_info = 38,
    event_data_reference_space_change_pending = 40,
    view_configuration_view = 41,
    space_location = 42,
    space_velocity = 43,
    frame_state = 44,
    view_configuration_properties = 45,
    frame_begin_info = 46,
    composition_layer_projection_view = 48,
    event_data_events_lost = 49,
    interaction_profile_suggested_binding = 51,
    event_data_interaction_profile_changed = 52,
    interaction_profile_state = 53,
    swapchain_image_acquire_info = 55,
    swapchain_image_wait_info = 56,
    swapchain_image_release_info = 57,
    action_state_get_info = 58,
    haptic_action_info = 59,
    session_action_sets_attach_info = 60,
    actions_sync_info = 61,
    bound_sources_for_action_enumerate_info = 62,
    input_source_localized_name_get_info = 63,
    spaces_locate_info = 1000471000,
    space_locations = 1000471001,
    space_velocities = 1000471002,
    composition_layer_cube_khr = 1000006000,
    instance_create_info_android_khr = 1000008000,
    composition_layer_depth_info_khr = 1000010000,
    vulkan_swapchain_format_list_create_info_khr = 1000014000,
    event_data_perf_settings_ext = 1000015000,
    composition_layer_cylinder_khr = 1000017000,
    composition_layer_equirect_khr = 1000018000,
    debug_utils_object_name_info_ext = 1000019000,
    debug_utils_messenger_callback_data_ext = 1000019001,
    debug_utils_messenger_create_info_ext = 1000019002,
    debug_utils_label_ext = 1000019003,
    graphics_binding_opengl_win32_khr = 1000023000,
    graphics_binding_opengl_xlib_khr = 1000023001,
    graphics_binding_opengl_xcb_khr = 1000023002,
    graphics_binding_opengl_wayland_khr = 1000023003,
    swapchain_image_opengl_khr = 1000023004,
    graphics_requirements_opengl_khr = 1000023005,
    graphics_binding_opengl_es_android_khr = 1000024001,
    swapchain_image_opengl_es_khr = 1000024002,
    graphics_requirements_opengl_es_khr = 1000024003,
    graphics_binding_vulkan_khr = 1000025000,
    swapchain_image_vulkan_khr = 1000025001,
    graphics_requirements_vulkan_khr = 1000025002,
    graphics_binding_d3d11_khr = 1000027000,
    swapchain_image_d3d11_khr = 1000027001,
    graphics_requirements_d3d11_khr = 1000027002,
    graphics_binding_d3d12_khr = 1000028000,
    swapchain_image_d3d12_khr = 1000028001,
    graphics_requirements_d3d12_khr = 1000028002,
    graphics_binding_metal_khr = 1000029000,
    swapchain_image_metal_khr = 1000029001,
    graphics_requirements_metal_khr = 1000029002,
    system_eye_gaze_interaction_properties_ext = 1000030000,
    eye_gaze_sample_time_ext = 1000030001,
    visibility_mask_khr = 1000031000,
    event_data_visibility_mask_changed_khr = 1000031001,
    session_create_info_overlay_extx = 1000033000,
    event_data_main_session_visibility_changed_extx = 1000033003,
    composition_layer_color_scale_bias_khr = 1000034000,
    spatial_anchor_create_info_msft = 1000039000,
    spatial_anchor_space_create_info_msft = 1000039001,
    composition_layer_image_layout_fb = 1000040000,
    composition_layer_alpha_blend_fb = 1000041001,
    view_configuration_depth_range_ext = 1000046000,
    graphics_binding_egl_mndx = 1000048004,
    spatial_graph_node_space_create_info_msft = 1000049000,
    spatial_graph_static_node_binding_create_info_msft = 1000049001,
    spatial_graph_node_binding_properties_get_info_msft = 1000049002,
    spatial_graph_node_binding_properties_msft = 1000049003,
    system_hand_tracking_properties_ext = 1000051000,
    hand_tracker_create_info_ext = 1000051001,
    hand_joints_locate_info_ext = 1000051002,
    hand_joint_locations_ext = 1000051003,
    hand_joint_velocities_ext = 1000051004,
    system_hand_tracking_mesh_properties_msft = 1000052000,
    hand_mesh_space_create_info_msft = 1000052001,
    hand_mesh_update_info_msft = 1000052002,
    hand_mesh_msft = 1000052003,
    hand_pose_type_info_msft = 1000052004,
    secondary_view_configuration_session_begin_info_msft = 1000053000,
    secondary_view_configuration_state_msft = 1000053001,
    secondary_view_configuration_frame_state_msft = 1000053002,
    secondary_view_configuration_frame_end_info_msft = 1000053003,
    secondary_view_configuration_layer_info_msft = 1000053004,
    secondary_view_configuration_swapchain_create_info_msft = 1000053005,
    controller_model_key_state_msft = 1000055000,
    controller_model_node_properties_msft = 1000055001,
    controller_model_properties_msft = 1000055002,
    controller_model_node_state_msft = 1000055003,
    controller_model_state_msft = 1000055004,
    view_configuration_view_fov_epic = 1000059000,
    holographic_window_attachment_msft = 1000063000,
    composition_layer_reprojection_info_msft = 1000066000,
    composition_layer_reprojection_plane_override_msft = 1000066001,
    android_surface_swapchain_create_info_fb = 1000070000,
    composition_layer_secure_content_fb = 1000072000,
    body_tracker_create_info_fb = 1000076001,
    body_joints_locate_info_fb = 1000076002,
    system_body_tracking_properties_fb = 1000076004,
    body_joint_locations_fb = 1000076005,
    body_skeleton_fb = 1000076006,
    interaction_profile_dpad_binding_ext = 1000078000,
    interaction_profile_analog_threshold_valve = 1000079000,
    hand_joints_motion_range_info_ext = 1000080000,
    loader_init_info_android_khr = 1000089000,
    vulkan_instance_create_info_khr = 1000090000,
    vulkan_device_create_info_khr = 1000090001,
    vulkan_graphics_device_get_info_khr = 1000090003,
    composition_layer_equirect2_khr = 1000091000,
    scene_observer_create_info_msft = 1000097000,
    scene_create_info_msft = 1000097001,
    new_scene_compute_info_msft = 1000097002,
    visual_mesh_compute_lod_info_msft = 1000097003,
    scene_components_msft = 1000097004,
    scene_components_get_info_msft = 1000097005,
    scene_component_locations_msft = 1000097006,
    scene_components_locate_info_msft = 1000097007,
    scene_objects_msft = 1000097008,
    scene_component_parent_filter_info_msft = 1000097009,
    scene_object_types_filter_info_msft = 1000097010,
    scene_planes_msft = 1000097011,
    scene_plane_alignment_filter_info_msft = 1000097012,
    scene_meshes_msft = 1000097013,
    scene_mesh_buffers_get_info_msft = 1000097014,
    scene_mesh_buffers_msft = 1000097015,
    scene_mesh_vertex_buffer_msft = 1000097016,
    scene_mesh_indices_uint32_msft = 1000097017,
    scene_mesh_indices_uint16_msft = 1000097018,
    serialized_scene_fragment_data_get_info_msft = 1000098000,
    scene_deserialize_info_msft = 1000098001,
    event_data_display_refresh_rate_changed_fb = 1000101000,
    vive_tracker_paths_htcx = 1000103000,
    event_data_vive_tracker_connected_htcx = 1000103001,
    system_facial_tracking_properties_htc = 1000104000,
    facial_tracker_create_info_htc = 1000104001,
    facial_expressions_htc = 1000104002,
    system_color_space_properties_fb = 1000108000,
    hand_tracking_mesh_fb = 1000110001,
    hand_tracking_scale_fb = 1000110003,
    hand_tracking_aim_state_fb = 1000111001,
    hand_tracking_capsules_state_fb = 1000112000,
    system_spatial_entity_properties_fb = 1000113004,
    spatial_anchor_create_info_fb = 1000113003,
    space_component_status_set_info_fb = 1000113007,
    space_component_status_fb = 1000113001,
    event_data_spatial_anchor_create_complete_fb = 1000113005,
    event_data_space_set_status_complete_fb = 1000113006,
    foveation_profile_create_info_fb = 1000114000,
    swapchain_create_info_foveation_fb = 1000114001,
    swapchain_state_foveation_fb = 1000114002,
    foveation_level_profile_create_info_fb = 1000115000,
    keyboard_space_create_info_fb = 1000116009,
    keyboard_tracking_query_fb = 1000116004,
    system_keyboard_tracking_properties_fb = 1000116002,
    triangle_mesh_create_info_fb = 1000117001,
    system_passthrough_properties_fb = 1000118000,
    passthrough_create_info_fb = 1000118001,
    passthrough_layer_create_info_fb = 1000118002,
    composition_layer_passthrough_fb = 1000118003,
    geometry_instance_create_info_fb = 1000118004,
    geometry_instance_transform_fb = 1000118005,
    system_passthrough_properties2_fb = 1000118006,
    passthrough_style_fb = 1000118020,
    passthrough_color_map_mono_to_rgba_fb = 1000118021,
    passthrough_color_map_mono_to_mono_fb = 1000118022,
    passthrough_brightness_contrast_saturation_fb = 1000118023,
    event_data_passthrough_state_changed_fb = 1000118030,
    render_model_path_info_fb = 1000119000,
    render_model_properties_fb = 1000119001,
    render_model_buffer_fb = 1000119002,
    render_model_load_info_fb = 1000119003,
    system_render_model_properties_fb = 1000119004,
    render_model_capabilities_request_fb = 1000119005,
    binding_modifications_khr = 1000120000,
    view_locate_foveated_rendering_varjo = 1000121000,
    foveated_view_configuration_view_varjo = 1000121001,
    system_foveated_rendering_properties_varjo = 1000121002,
    composition_layer_depth_test_varjo = 1000122000,
    system_marker_tracking_properties_varjo = 1000124000,
    event_data_marker_tracking_update_varjo = 1000124001,
    marker_space_create_info_varjo = 1000124002,
    frame_end_info_ml = 1000135000,
    global_dimmer_frame_end_info_ml = 1000136000,
    coordinate_space_create_info_ml = 1000137000,
    system_marker_understanding_properties_ml = 1000138000,
    marker_detector_create_info_ml = 1000138001,
    marker_detector_aruco_info_ml = 1000138002,
    marker_detector_size_info_ml = 1000138003,
    marker_detector_april_tag_info_ml = 1000138004,
    marker_detector_custom_profile_info_ml = 1000138005,
    marker_detector_snapshot_info_ml = 1000138006,
    marker_detector_state_ml = 1000138007,
    marker_space_create_info_ml = 1000138008,
    localization_map_ml = 1000139000,
    event_data_localization_changed_ml = 1000139001,
    map_localization_request_info_ml = 1000139002,
    localization_map_import_info_ml = 1000139003,
    localization_enable_events_info_ml = 1000139004,
    spatial_anchors_create_info_from_pose_ml = 1000140000,
    create_spatial_anchors_completion_ml = 1000140001,
    spatial_anchor_state_ml = 1000140002,
    spatial_anchors_create_storage_info_ml = 1000141000,
    spatial_anchors_query_info_radius_ml = 1000141001,
    spatial_anchors_query_completion_ml = 1000141002,
    spatial_anchors_create_info_from_uuids_ml = 1000141003,
    spatial_anchors_publish_info_ml = 1000141004,
    spatial_anchors_publish_completion_ml = 1000141005,
    spatial_anchors_delete_info_ml = 1000141006,
    spatial_anchors_delete_completion_ml = 1000141007,
    spatial_anchors_update_expiration_info_ml = 1000141008,
    spatial_anchors_update_expiration_completion_ml = 1000141009,
    spatial_anchors_publish_completion_details_ml = 1000141010,
    spatial_anchors_delete_completion_details_ml = 1000141011,
    spatial_anchors_update_expiration_completion_details_ml = 1000141012,
    event_data_headset_fit_changed_ml = 1000472000,
    event_data_eye_calibration_changed_ml = 1000472001,
    user_calibration_enable_events_info_ml = 1000472002,
    spatial_anchor_persistence_info_msft = 1000142000,
    spatial_anchor_from_persisted_anchor_create_info_msft = 1000142001,
    scene_markers_msft = 1000147000,
    scene_marker_type_filter_msft = 1000147001,
    scene_marker_qr_codes_msft = 1000147002,
    space_query_info_fb = 1000156001,
    space_query_results_fb = 1000156002,
    space_storage_location_filter_info_fb = 1000156003,
    space_uuid_filter_info_fb = 1000156054,
    space_component_filter_info_fb = 1000156052,
    event_data_space_query_results_available_fb = 1000156103,
    event_data_space_query_complete_fb = 1000156104,
    space_save_info_fb = 1000158000,
    space_erase_info_fb = 1000158001,
    event_data_space_save_complete_fb = 1000158106,
    event_data_space_erase_complete_fb = 1000158107,
    swapchain_image_foveation_vulkan_fb = 1000160000,
    swapchain_state_android_surface_dimensions_fb = 1000161000,
    swapchain_state_sampler_opengl_es_fb = 1000162000,
    swapchain_state_sampler_vulkan_fb = 1000163000,
    space_share_info_fb = 1000169001,
    event_data_space_share_complete_fb = 1000169002,
    composition_layer_space_warp_info_fb = 1000171000,
    system_space_warp_properties_fb = 1000171001,
    haptic_amplitude_envelope_vibration_fb = 1000173001,
    semantic_labels_fb = 1000175000,
    room_layout_fb = 1000175001,
    boundary_2d_fb = 1000175002,
    semantic_labels_support_info_fb = 1000175010,
    digital_lens_control_almalence = 1000196000,
    event_data_scene_capture_complete_fb = 1000198001,
    scene_capture_request_info_fb = 1000198050,
    space_container_fb = 1000199000,
    foveation_eye_tracked_profile_create_info_meta = 1000200000,
    foveation_eye_tracked_state_meta = 1000200001,
    system_foveation_eye_tracked_properties_meta = 1000200002,
    system_face_tracking_properties_fb = 1000201004,
    face_tracker_create_info_fb = 1000201005,
    face_expression_info_fb = 1000201002,
    face_expression_weights_fb = 1000201006,
    eye_tracker_create_info_fb = 1000202001,
    eye_gazes_info_fb = 1000202002,
    eye_gazes_fb = 1000202003,
    system_eye_tracking_properties_fb = 1000202004,
    passthrough_keyboard_hands_intensity_fb = 1000203002,
    composition_layer_settings_fb = 1000204000,
    haptic_pcm_vibration_fb = 1000209001,
    device_pcm_sample_rate_state_fb = 1000209002,
    frame_synthesis_info_ext = 1000211000,
    frame_synthesis_config_view_ext = 1000211001,
    composition_layer_depth_test_fb = 1000212000,
    local_dimming_frame_end_info_meta = 1000216000,
    passthrough_preferences_meta = 1000217000,
    system_virtual_keyboard_properties_meta = 1000219001,
    virtual_keyboard_create_info_meta = 1000219002,
    virtual_keyboard_space_create_info_meta = 1000219003,
    virtual_keyboard_location_info_meta = 1000219004,
    virtual_keyboard_model_visibility_set_info_meta = 1000219005,
    virtual_keyboard_animation_state_meta = 1000219006,
    virtual_keyboard_model_animation_states_meta = 1000219007,
    virtual_keyboard_texture_data_meta = 1000219009,
    virtual_keyboard_input_info_meta = 1000219010,
    virtual_keyboard_text_context_change_info_meta = 1000219011,
    event_data_virtual_keyboard_commit_text_meta = 1000219014,
    event_data_virtual_keyboard_backspace_meta = 1000219015,
    event_data_virtual_keyboard_enter_meta = 1000219016,
    event_data_virtual_keyboard_shown_meta = 1000219017,
    event_data_virtual_keyboard_hidden_meta = 1000219018,
    external_camera_oculus = 1000226000,
    vulkan_swapchain_create_info_meta = 1000227000,
    performance_metrics_state_meta = 1000232001,
    performance_metrics_counter_meta = 1000232002,
    space_list_save_info_fb = 1000238000,
    event_data_space_list_save_complete_fb = 1000238001,
    space_user_create_info_fb = 1000241001,
    system_headset_id_properties_meta = 1000245000,
    recommended_layer_resolution_meta = 1000254000,
    recommended_layer_resolution_get_info_meta = 1000254001,
    system_passthrough_color_lut_properties_meta = 1000266000,
    passthrough_color_lut_create_info_meta = 1000266001,
    passthrough_color_lut_update_info_meta = 1000266002,
    passthrough_color_map_lut_meta = 1000266100,
    passthrough_color_map_interpolated_lut_meta = 1000266101,
    space_triangle_mesh_get_info_meta = 1000269001,
    space_triangle_mesh_meta = 1000269002,
    event_data_passthrough_layer_resumed_meta = 1000282000,
    system_face_tracking_properties2_fb = 1000287013,
    face_tracker_create_info2_fb = 1000287014,
    face_expression_info2_fb = 1000287015,
    face_expression_weights2_fb = 1000287016,
    system_spatial_entity_sharing_properties_meta = 1000290000,
    share_spaces_info_meta = 1000290001,
    event_data_share_spaces_complete_meta = 1000290002,
    environment_depth_provider_create_info_meta = 1000291000,
    environment_depth_swapchain_create_info_meta = 1000291001,
    environment_depth_swapchain_state_meta = 1000291002,
    environment_depth_image_acquire_info_meta = 1000291003,
    environment_depth_image_view_meta = 1000291004,
    environment_depth_image_meta = 1000291005,
    environment_depth_hand_removal_set_info_meta = 1000291006,
    system_environment_depth_properties_meta = 1000291007,
    passthrough_create_info_htc = 1000317001,
    passthrough_color_htc = 1000317002,
    passthrough_mesh_transform_info_htc = 1000317003,
    composition_layer_passthrough_htc = 1000317004,
    foveation_apply_info_htc = 1000318000,
    foveation_dynamic_mode_info_htc = 1000318001,
    foveation_custom_mode_info_htc = 1000318002,
    system_anchor_properties_htc = 1000319000,
    spatial_anchor_create_info_htc = 1000319001,
    system_body_tracking_properties_htc = 1000320000,
    body_tracker_create_info_htc = 1000320001,
    body_joints_locate_info_htc = 1000320002,
    body_joint_locations_htc = 1000320003,
    body_skeleton_htc = 1000320004,
    active_action_set_priorities_ext = 1000373000,
    system_force_feedback_curl_properties_mndx = 1000375000,
    force_feedback_curl_apply_locations_mndx = 1000375001,
    body_tracker_create_info_bd = 1000385001,
    body_joints_locate_info_bd = 1000385002,
    body_joint_locations_bd = 1000385003,
    system_body_tracking_properties_bd = 1000385004,
    system_spatial_sensing_properties_bd = 1000389000,
    spatial_entity_component_get_info_bd = 1000389001,
    spatial_entity_location_get_info_bd = 1000389002,
    spatial_entity_component_data_location_bd = 1000389003,
    spatial_entity_component_data_semantic_bd = 1000389004,
    spatial_entity_component_data_bounding_box_2d_bd = 1000389005,
    spatial_entity_component_data_polygon_bd = 1000389006,
    spatial_entity_component_data_bounding_box_3d_bd = 1000389007,
    spatial_entity_component_data_triangle_mesh_bd = 1000389008,
    sense_data_provider_create_info_bd = 1000389009,
    sense_data_provider_start_info_bd = 1000389010,
    event_data_sense_data_provider_state_changed_bd = 1000389011,
    event_data_sense_data_updated_bd = 1000389012,
    sense_data_query_info_bd = 1000389013,
    sense_data_query_completion_bd = 1000389014,
    sense_data_filter_uuid_bd = 1000389015,
    sense_data_filter_semantic_bd = 1000389016,
    queried_sense_data_get_info_bd = 1000389017,
    queried_sense_data_bd = 1000389018,
    spatial_entity_state_bd = 1000389019,
    spatial_entity_anchor_create_info_bd = 1000389020,
    anchor_space_create_info_bd = 1000389021,
    system_spatial_anchor_properties_bd = 1000390000,
    spatial_anchor_create_info_bd = 1000390001,
    spatial_anchor_create_completion_bd = 1000390002,
    spatial_anchor_persist_info_bd = 1000390003,
    spatial_anchor_unpersist_info_bd = 1000390004,
    system_spatial_anchor_sharing_properties_bd = 1000391000,
    spatial_anchor_share_info_bd = 1000391001,
    shared_spatial_anchor_download_info_bd = 1000391002,
    system_spatial_scene_properties_bd = 1000392000,
    scene_capture_info_bd = 1000392001,
    system_spatial_mesh_properties_bd = 1000393000,
    sense_data_provider_create_info_spatial_mesh_bd = 1000393001,
    hand_tracking_data_source_info_ext = 1000428000,
    hand_tracking_data_source_state_ext = 1000428001,
    plane_detector_create_info_ext = 1000429001,
    plane_detector_begin_info_ext = 1000429002,
    plane_detector_get_info_ext = 1000429003,
    plane_detector_locations_ext = 1000429004,
    plane_detector_location_ext = 1000429005,
    plane_detector_polygon_buffer_ext = 1000429006,
    system_plane_detection_properties_ext = 1000429007,
    future_cancel_info_ext = 1000469000,
    future_poll_info_ext = 1000469001,
    future_completion_ext = 1000469002,
    future_poll_result_ext = 1000469003,
    event_data_user_presence_changed_ext = 1000470000,
    system_user_presence_properties_ext = 1000470001,
    system_notifications_set_info_ml = 1000473000,
    world_mesh_detector_create_info_ml = 1000474001,
    world_mesh_state_request_info_ml = 1000474002,
    world_mesh_block_state_ml = 1000474003,
    world_mesh_state_request_completion_ml = 1000474004,
    world_mesh_buffer_recommended_size_info_ml = 1000474005,
    world_mesh_buffer_size_ml = 1000474006,
    world_mesh_buffer_ml = 1000474007,
    world_mesh_block_request_ml = 1000474008,
    world_mesh_get_info_ml = 1000474009,
    world_mesh_block_ml = 1000474010,
    world_mesh_request_completion_ml = 1000474011,
    world_mesh_request_completion_info_ml = 1000474012,
    system_facial_expression_properties_ml = 1000482004,
    facial_expression_client_create_info_ml = 1000482005,
    facial_expression_blend_shape_get_info_ml = 1000482006,
    facial_expression_blend_shape_properties_ml = 1000482007,
    colocation_discovery_start_info_meta = 1000571010,
    colocation_discovery_stop_info_meta = 1000571011,
    colocation_advertisement_start_info_meta = 1000571012,
    colocation_advertisement_stop_info_meta = 1000571013,
    event_data_start_colocation_advertisement_complete_meta = 1000571020,
    event_data_stop_colocation_advertisement_complete_meta = 1000571021,
    event_data_colocation_advertisement_complete_meta = 1000571022,
    event_data_start_colocation_discovery_complete_meta = 1000571023,
    event_data_colocation_discovery_result_meta = 1000571024,
    event_data_colocation_discovery_complete_meta = 1000571025,
    event_data_stop_colocation_discovery_complete_meta = 1000571026,
    system_colocation_discovery_properties_meta = 1000571030,
    share_spaces_recipient_groups_meta = 1000572000,
    space_group_uuid_filter_info_meta = 1000572001,
    system_spatial_entity_group_sharing_properties_meta = 1000572100,
};

pub const InstanceFnPtrs = struct {
    xrPollEvent: c.PFN_xrPollEvent,
    xrDestroySession: c.PFN_xrDestroySession,
    xrDestroyInstance: c.PFN_xrDestroyInstance,
};

pub fn loadFnPtrs(get_proc_addr: c.PFN_xrGetInstanceProcAddr, instance: c.XrInstance, comptime T: type) ResultError!T {
    var ret: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var func: c.PFN_xrVoidFunction = undefined;
        try convertResult(get_proc_addr.?(instance, field.name.ptr, &func));
        @field(ret, field.name) = @ptrCast(func.?);
    }
    return ret;
}

pub const SessionState = enum(c.XrSessionState) {
    idle = 1,
    ready = 2,
    synchronized = 3,
    visible = 4,
    focused = 5,
    stopping = 6,
    loss_pending = 7,
    exiting = 8,
};

pub const Event = extern union {
    pub const DataBuffer = extern struct {
        type: StructureType = .event_data_buffer,
        next: ?*anyopaque = null,
        varying: [4000]u8,

        comptime {
            std.debug.assert(@sizeOf(DataBuffer) == @sizeOf(c.XrEventDataBuffer));
            std.debug.assert(@offsetOf(DataBuffer, "type") == @offsetOf(c.XrEventDataBuffer, "type"));
            std.debug.assert(@offsetOf(DataBuffer, "next") == @offsetOf(c.XrEventDataBuffer, "next"));
            std.debug.assert(@offsetOf(DataBuffer, "varying") == @offsetOf(c.XrEventDataBuffer, "varying"));
        }
    };

    pub const SessionStateChanged = extern struct {
        type: StructureType = .event_data_buffer,
        next: ?*anyopaque = null,
        session: c.XrSession,
        state: SessionState,
        time: Time,
    };

    data_buffer: DataBuffer,
    session_state_changed: SessionStateChanged,

    pub fn to(self: *Event) *c.XrEventDataBuffer {
        return @ptrCast(self);
    }
};

pub const PollEventError = error{
    error_validation_failure,
    error_runtime_failure,
    error_handle_invalid,
    error_instance_lost,
};

pub const DestroySessionError = error{error_handle_invalid};

pub const DestroyInstanceError = error{error_handle_invalid};

pub const Instance = struct {
    value: c.XrInstance,

    fn_ptrs: InstanceFnPtrs,

    pub fn pollEvent(self: Instance, out: *Event) PollEventError!bool {
        convertResult(self.fn_ptrs.xrPollEvent.?(self.value, out.to())) catch |err| {
            switch (err) {
                ResultError.event_unavailable => return false,

                ResultError.error_runtime_failure,
                ResultError.error_instance_lost,
                ResultError.error_handle_invalid,
                ResultError.error_validation_failure,
                => |caught_err| return caught_err,

                // SAFETY: according to the specification, no other errors are reachable
                else => unreachable,
            }
        };

        return true;
    }

    pub fn destroySession(self: Instance, session: Session) DestroySessionError!void {
        return convertResult(self.fn_ptrs.xrDestroySession.?(session.value)) catch |err| {
            if (err == DestroySessionError.error_handle_invalid)
                return DestroySessionError.error_handle_invalid;

            // SAFETY: spec says no other errors are possible
            unreachable;
        };
    }

    pub fn deinit(self: Instance) DestroyInstanceError!void {
        return convertResult(self.fn_ptrs.xrDestroyInstance.?(self.value)) catch |err| {
            if (err == DestroyInstanceError.error_handle_invalid)
                return DestroyInstanceError.error_handle_invalid;

            // SAFETY: spec says no other errors are possible
            unreachable;
        };
    }
};

pub const Version = packed struct(c.XrVersion) {
    patch: u32,
    minor: u16,
    major: u16,
};

pub const FormFactor = enum(c.XrFormFactor) {
    head_mounted_display = 1,
    handheld_display = 2,
};

pub const Session = extern struct {
    value: c.XrSession,

    pub const CreateFlags = packed struct(c.XrSessionCreateFlags) {
        padding: u64 = 0,
    };

    pub const CreateInfo = extern struct {
        type: StructureType = .session_create_info,
        next: ?*anyopaque = null,
        flags: CreateFlags,
        system_id: SystemId,

        // ABI asserts
        comptime {
            std.debug.assert(@sizeOf(Session.CreateInfo) == @sizeOf(c.XrSessionCreateInfo));
            std.debug.assert(@offsetOf(Session.CreateInfo, "type") == @offsetOf(c.XrSessionCreateInfo, "type"));
            std.debug.assert(@offsetOf(Session.CreateInfo, "next") == @offsetOf(c.XrSessionCreateInfo, "next"));
            std.debug.assert(@offsetOf(Session.CreateInfo, "flags") == @offsetOf(c.XrSessionCreateInfo, "createFlags"));
            std.debug.assert(@offsetOf(Session.CreateInfo, "system_id") == @offsetOf(c.XrSessionCreateInfo, "systemId"));
        }

        pub fn to(create_info: CreateInfo) c.XrSessionCreateInfo {
            return @bitCast(create_info);
        }
    };

    pub fn from(session: c.XrSession) Session {
        return .{ .value = session };
    }
};

pub const Swapchain = extern struct {
    value: c.XrSwapchain,

    pub const CreateFlags = packed struct(c.XrSwapchainCreateFlags) {
        protected_content: bool,
        static_image: bool,
        padding: u62 = 0,
    };
    pub const UsageFlags = packed struct(c.XrSwapchainUsageFlags) {
        color_attachment: bool,
        depth_stencil_attachment: bool,
        unordered_access: bool,
        transfer_src: bool,
        transfer_dst: bool,
        sampled: bool,
        mutable_format: bool,
        input_attachment: bool,
        padding: u56 = 0,
    };

    pub const CreateInfo = extern struct {
        type: StructureType = .swapchain_create_info,
        next: ?*anyopaque = null,
        create_flags: CreateFlags,
        usage_flags: UsageFlags,
        format: i64,
        sample_count: u32,
        width: u32,
        height: u32,
        face_count: u32,
        array_size: u32,
        mip_count: u32,

        // ABI asserts
        comptime {
            std.debug.assert(@sizeOf(CreateInfo) == @sizeOf(c.XrSwapchainCreateInfo));
            std.debug.assert(@offsetOf(CreateInfo, "type") == @offsetOf(c.XrSwapchainCreateInfo, "type"));
            std.debug.assert(@offsetOf(CreateInfo, "next") == @offsetOf(c.XrSwapchainCreateInfo, "next"));
            std.debug.assert(@offsetOf(CreateInfo, "create_flags") == @offsetOf(c.XrSwapchainCreateInfo, "createFlags"));
            std.debug.assert(@offsetOf(CreateInfo, "usage_flags") == @offsetOf(c.XrSwapchainCreateInfo, "usageFlags"));
            std.debug.assert(@offsetOf(CreateInfo, "format") == @offsetOf(c.XrSwapchainCreateInfo, "format"));
            std.debug.assert(@offsetOf(CreateInfo, "sample_count") == @offsetOf(c.XrSwapchainCreateInfo, "sampleCount"));
            std.debug.assert(@offsetOf(CreateInfo, "width") == @offsetOf(c.XrSwapchainCreateInfo, "width"));
            std.debug.assert(@offsetOf(CreateInfo, "height") == @offsetOf(c.XrSwapchainCreateInfo, "height"));
            std.debug.assert(@offsetOf(CreateInfo, "face_count") == @offsetOf(c.XrSwapchainCreateInfo, "faceCount"));
            std.debug.assert(@offsetOf(CreateInfo, "array_size") == @offsetOf(c.XrSwapchainCreateInfo, "arraySize"));
            std.debug.assert(@offsetOf(CreateInfo, "mip_count") == @offsetOf(c.XrSwapchainCreateInfo, "mipCount"));
        }

        pub fn to(create_info: CreateInfo) c.XrSwapchainCreateInfo {
            return @bitCast(create_info);
        }
    };

    pub fn from(swapchain: c.XrSwapchain) Swapchain {
        return .{ .value = swapchain };
    }
};

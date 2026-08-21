#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <poll.h>
#include <set>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>

namespace {

constexpr std::uint32_t protocol_magic = 0x4845544e;
constexpr std::uint16_t protocol_version = 1;
constexpr std::size_t maximum_keys = 6;
constexpr auto heartbeat_timeout = std::chrono::seconds(1);

enum class command : std::uint16_t {
  hello = 1,
  status = 2,
  set_report = 3,
  heartbeat = 4,
  release_all = 5,
  error = 6,
};

enum class bridge_status : std::uint32_t {
  unknown = 0,
  ready = 1,
  daemon_unavailable = 2,
  driver_inactive = 3,
  driver_disconnected = 4,
  version_mismatch = 5,
  keyboard_not_ready = 6,
  protocol_error = 7,
};

struct __attribute__((packed)) protocol_frame final {
  std::uint32_t magic{protocol_magic};
  std::uint16_t version{protocol_version};
  std::uint16_t command_value{0};
  std::uint64_t sequence{0};
  std::uint32_t status_value{0};
  std::uint8_t modifiers{0};
  std::uint8_t key_count{0};
  std::uint16_t reserved{0};
  std::uint16_t keys[maximum_keys]{};
  std::uint8_t padding[28]{};
};

static_assert(sizeof(protocol_frame) == 64);

std::atomic<bool> exit_requested{false};

void handle_signal(int) {
  exit_requested = true;
}

struct driver_state final {
  std::atomic<bool> daemon_connected{false};
  std::atomic<bool> driver_activated{false};
  std::atomic<bool> driver_connected{false};
  std::atomic<bool> version_mismatched{false};
  std::atomic<bool> keyboard_ready{false};

  bridge_status status() const {
    if (version_mismatched) {
      return bridge_status::version_mismatch;
    }
    if (!daemon_connected) {
      return bridge_status::daemon_unavailable;
    }
    if (!driver_activated) {
      return bridge_status::driver_inactive;
    }
    if (!driver_connected) {
      return bridge_status::driver_disconnected;
    }
    if (!keyboard_ready) {
      return bridge_status::keyboard_not_ready;
    }
    return bridge_status::ready;
  }
};

using service_client = pqrs::karabiner::driverkit::virtual_hid_device_service::client;
using keyboard_report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::keyboard_input;
using report_modifier = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report::modifier;

keyboard_report make_report(const protocol_frame& frame);

bool is_allowed_usage(std::uint16_t usage) {
  static const std::set<std::uint16_t> allowed{
      0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0d, 0x10, 0x11,
      0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
  };
  return allowed.contains(usage);
}

bool validate_frame(const protocol_frame& frame) {
  if (frame.magic != protocol_magic || frame.version != protocol_version || frame.reserved != 0) {
    return false;
  }
  for (const auto byte : frame.padding) {
    if (byte != 0) {
      return false;
    }
  }
  if ((frame.modifiers & ~std::uint8_t{0x03}) != 0 || frame.key_count > maximum_keys) {
    return false;
  }
  std::set<std::uint16_t> keys;
  for (std::size_t index = 0; index < maximum_keys; ++index) {
    const auto usage = frame.keys[index];
    if (index < frame.key_count) {
      if (!is_allowed_usage(usage) || !keys.insert(usage).second) {
        return false;
      }
    } else if (usage != 0) {
      return false;
    }
  }
  if (frame.command_value < static_cast<std::uint16_t>(command::hello) ||
      frame.command_value > static_cast<std::uint16_t>(command::release_all)) {
    return false;
  }
  const auto request_command = static_cast<command>(frame.command_value);
  if (request_command != command::set_report && (frame.modifiers != 0 || frame.key_count != 0)) {
    return false;
  }
  return true;
}

bool validate_sequence(command request_command, std::uint64_t sequence, std::uint64_t& last_sequence) {
  if (request_command != command::set_report && request_command != command::heartbeat && request_command != command::release_all) {
    return true;
  }
  if (sequence == 0 || sequence <= last_sequence) {
    return false;
  }
  last_sequence = sequence;
  return true;
}

bool peer_is_allowed(uid_t peer_uid, uid_t allowed_uid) {
  return peer_uid == allowed_uid && allowed_uid != 0;
}

bool heartbeat_expired(
    bool report_nonempty,
    std::chrono::steady_clock::time_point last_activity,
    std::chrono::steady_clock::time_point now) {
  return report_nonempty && now - last_activity >= heartbeat_timeout;
}

bool run_self_test() {
  protocol_frame valid;
  valid.command_value = static_cast<std::uint16_t>(command::set_report);
  valid.sequence = 1;
  valid.modifiers = 0x02;
  valid.key_count = 2;
  valid.keys[0] = 0x04;
  valid.keys[1] = 0x14;
  if (!validate_frame(valid)) {
    return false;
  }
  auto invalid = valid;
  invalid.keys[1] = invalid.keys[0];
  if (validate_frame(invalid)) {
    return false;
  }
  invalid = valid;
  invalid.keys[1] = 0x2c;
  if (validate_frame(invalid)) {
    return false;
  }
  invalid = valid;
  invalid.padding[0] = 1;
  if (validate_frame(invalid)) {
    return false;
  }
  invalid = valid;
  invalid.command_value = static_cast<std::uint16_t>(command::heartbeat);
  if (validate_frame(invalid)) {
    return false;
  }
  std::uint64_t last_sequence = 0;
  if (!validate_sequence(command::set_report, 1, last_sequence) ||
      validate_sequence(command::heartbeat, 1, last_sequence) ||
      !validate_sequence(command::heartbeat, 2, last_sequence)) {
    return false;
  }
  if (!peer_is_allowed(501, 501) || peer_is_allowed(502, 501) || peer_is_allowed(0, 0)) {
    return false;
  }
  const auto now = std::chrono::steady_clock::now();
  if (!heartbeat_expired(true, now - heartbeat_timeout, now) ||
      heartbeat_expired(true, now - std::chrono::milliseconds(999), now) ||
      heartbeat_expired(false, now - heartbeat_timeout, now)) {
    return false;
  }
  const auto report = make_report(valid);
  return report.modifiers.exists(report_modifier::left_shift) && report.keys.count() == 2;
}

keyboard_report make_report(const protocol_frame& frame) {
  keyboard_report report;
  if ((frame.modifiers & 0x01) != 0) {
    report.modifiers.insert(report_modifier::left_control);
  }
  if ((frame.modifiers & 0x02) != 0) {
    report.modifiers.insert(report_modifier::left_shift);
  }
  for (std::size_t index = 0; index < frame.key_count; ++index) {
    report.keys.insert(frame.keys[index]);
  }
  return report;
}

bool read_exactly(int descriptor, void* buffer, std::size_t size) {
  auto* bytes = static_cast<std::uint8_t*>(buffer);
  std::size_t received = 0;
  while (received < size && !exit_requested) {
    const auto result = ::read(descriptor, bytes + received, size - received);
    if (result > 0) {
      received += static_cast<std::size_t>(result);
      continue;
    }
    if (result < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
  return received == size;
}

bool write_exactly(int descriptor, const void* buffer, std::size_t size) {
  const auto* bytes = static_cast<const std::uint8_t*>(buffer);
  std::size_t sent = 0;
  while (sent < size && !exit_requested) {
    const auto result = ::write(descriptor, bytes + sent, size - sent);
    if (result > 0) {
      sent += static_cast<std::size_t>(result);
      continue;
    }
    if (result < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
  return sent == size;
}

protocol_frame response_for(const protocol_frame& request, bridge_status status, command response_command = command::status) {
  protocol_frame response;
  response.command_value = static_cast<std::uint16_t>(response_command);
  response.sequence = request.sequence;
  response.status_value = static_cast<std::uint32_t>(status);
  return response;
}

std::optional<uid_t> parse_allowed_uid(int argc, char* argv[]) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (std::string(argv[index]) == "--allowed-uid") {
      try {
        const auto value = std::stoul(argv[index + 1]);
        if (value <= std::numeric_limits<uid_t>::max()) {
          return static_cast<uid_t>(value);
        }
      } catch (...) {
        return std::nullopt;
      }
    }
  }
  return std::nullopt;
}

int make_listening_socket(const std::string& path, uid_t allowed_uid) {
  const auto descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (descriptor < 0) {
    return -1;
  }

  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path)) {
    ::close(descriptor);
    errno = ENAMETOOLONG;
    return -1;
  }
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  ::unlink(path.c_str());
  if (::bind(descriptor, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      ::chown(path.c_str(), allowed_uid, static_cast<gid_t>(-1)) != 0 ||
      ::chmod(path.c_str(), S_IRUSR | S_IWUSR) != 0 ||
      ::listen(descriptor, 1) != 0) {
    const auto saved_errno = errno;
    ::close(descriptor);
    ::unlink(path.c_str());
    errno = saved_errno;
    return -1;
  }
  return descriptor;
}

void post_empty_report(service_client& client, std::mutex& client_mutex) {
  std::lock_guard<std::mutex> lock(client_mutex);
  client.async_post_report(keyboard_report{});
}

void serve_client(
    int descriptor,
    uid_t allowed_uid,
    service_client& hid_client,
    std::mutex& client_mutex,
    const driver_state& state) {
  uid_t peer_uid = 0;
  gid_t peer_gid = 0;
  if (::getpeereid(descriptor, &peer_uid, &peer_gid) != 0 || !peer_is_allowed(peer_uid, allowed_uid)) {
    std::cerr << "Rejected VirtualHID client with uid " << peer_uid << "." << std::endl;
    return;
  }

  int no_sigpipe = 1;
  ::setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
  timeval timeout{1, 0};
  ::setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  ::setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

  std::uint64_t last_sequence = 0;
  bool report_nonempty = false;
  auto last_activity = std::chrono::steady_clock::now();

  while (!exit_requested) {
    pollfd poll_descriptor{descriptor, POLLIN, 0};
    const auto poll_result = ::poll(&poll_descriptor, 1, 100);
    if (poll_result < 0 && errno != EINTR) {
      break;
    }
    if (poll_result > 0 && (poll_descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      break;
    }
    if (poll_result > 0 && (poll_descriptor.revents & POLLIN) != 0) {
      protocol_frame request;
      if (!read_exactly(descriptor, &request, sizeof(request))) {
        break;
      }
      if (!validate_frame(request)) {
        const auto response = response_for(request, bridge_status::protocol_error, command::error);
        write_exactly(descriptor, &response, sizeof(response));
        break;
      }

      const auto request_command = static_cast<command>(request.command_value);
      if (!validate_sequence(request_command, request.sequence, last_sequence)) {
        const auto response = response_for(request, bridge_status::protocol_error, command::error);
        write_exactly(descriptor, &response, sizeof(response));
        break;
      }

      const auto current_status = state.status();
      if (current_status == bridge_status::ready) {
        if (request_command == command::set_report) {
          std::lock_guard<std::mutex> lock(client_mutex);
          hid_client.async_post_report(make_report(request));
          report_nonempty = request.modifiers != 0 || request.key_count != 0;
        } else if (request_command == command::release_all) {
          post_empty_report(hid_client, client_mutex);
          report_nonempty = false;
        }
      }
      if (request_command == command::set_report || request_command == command::heartbeat || request_command == command::release_all) {
        last_activity = std::chrono::steady_clock::now();
      }
      const auto response = response_for(request, current_status);
      if (!write_exactly(descriptor, &response, sizeof(response))) {
        break;
      }
    }

    if (heartbeat_expired(report_nonempty, last_activity, std::chrono::steady_clock::now())) {
      post_empty_report(hid_client, client_mutex);
      report_nonempty = false;
      std::cerr << "Heartbeat timeout; released the virtual keyboard." << std::endl;
    }
  }

  if (report_nonempty) {
    post_empty_report(hid_client, client_mutex);
  }
}

} // namespace

int main(int argc, char* argv[]) {
  if (argc == 2 && std::string(argv[1]) == "--self-test") {
    if (run_self_test()) {
      std::cout << "NTEVirtualHIDBridge self-test passed." << std::endl;
      return 0;
    }
    std::cerr << "NTEVirtualHIDBridge self-test failed." << std::endl;
    return 1;
  }
  if (::geteuid() != 0) {
    std::cerr << "NTEVirtualHIDBridge must run as root. Use sudo." << std::endl;
    return 64;
  }
  const auto allowed_uid = parse_allowed_uid(argc, argv);
  if (!allowed_uid || *allowed_uid == 0) {
    std::cerr << "Usage: NTEVirtualHIDBridge --allowed-uid <non-root uid>" << std::endl;
    return 64;
  }

  std::signal(SIGINT, handle_signal);
  std::signal(SIGTERM, handle_signal);
  std::signal(SIGPIPE, SIG_IGN);

  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  driver_state state;
  std::mutex client_mutex;
  auto hid_client = std::make_unique<service_client>();

  hid_client->warning_reported.connect([](const auto& message) {
    std::cerr << "Karabiner warning: " << message << std::endl;
  });
  hid_client->connected.connect([&] {
    state.daemon_connected = true;
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters parameters;
    parameters.set_country_code(pqrs::hid::country_code::us);
    std::lock_guard<std::mutex> lock(client_mutex);
    hid_client->async_virtual_hid_keyboard_initialize(parameters);
  });
  hid_client->connect_failed.connect([&](const auto&) { state.daemon_connected = false; });
  hid_client->closed.connect([&] {
    state.daemon_connected = false;
    state.keyboard_ready = false;
  });
  hid_client->error_occurred.connect([&](const auto& error) {
    std::cerr << "Karabiner client error: " << error.message() << std::endl;
  });
  hid_client->driver_activated.connect([&](bool value) { state.driver_activated = value; });
  hid_client->driver_connected.connect([&](bool value) { state.driver_connected = value; });
  hid_client->driver_version_mismatched.connect([&](bool value) { state.version_mismatched = value; });
  hid_client->virtual_hid_keyboard_ready.connect([&](bool value) { state.keyboard_ready = value; });
  hid_client->async_start();

  const auto socket_path = "/var/run/nte-piano-midi-player-" + std::to_string(*allowed_uid) + ".sock";
  const auto listening_socket = make_listening_socket(socket_path, *allowed_uid);
  if (listening_socket < 0) {
    std::cerr << "Could not create " << socket_path << ": " << std::strerror(errno) << std::endl;
    hid_client = nullptr;
    pqrs::dispatcher::extra::terminate_shared_dispatcher();
    return 1;
  }

  std::cout << "NTE VirtualHID bridge listening at " << socket_path << std::endl;
  std::cout << "Allowed GUI uid: " << *allowed_uid << std::endl;
  std::cout << "Press Control-C to stop." << std::endl;

  while (!exit_requested) {
    pollfd descriptor{listening_socket, POLLIN, 0};
    const auto result = ::poll(&descriptor, 1, 250);
    if (result < 0 && errno != EINTR) {
      break;
    }
    if (result > 0 && (descriptor.revents & POLLIN) != 0) {
      const auto accepted = ::accept(listening_socket, nullptr, nullptr);
      if (accepted >= 0) {
        serve_client(accepted, *allowed_uid, *hid_client, client_mutex, state);
        ::close(accepted);
      }
    }
  }

  post_empty_report(*hid_client, client_mutex);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  ::close(listening_socket);
  ::unlink(socket_path.c_str());
  hid_client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  return 0;
}

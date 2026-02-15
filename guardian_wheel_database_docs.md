
# Guardian Wheel – Database Documentation

## Environment

- **Project Name:** Guardian Wheel  
- **Project ID:** 699166ea0002abced333  
- **Endpoint:** https://fra.cloud.appwrite.io/v1  

---

## Database: `guardian-wheel-db`

This database supports rider safety, emergency handling, mesh networking, and hazard intelligence.

---

## Table: `users`
**Purpose:** Rider profile

| Field | Type | Required | Notes |
|---|---|---|---|
| name | string | ✅ | Rider full name |
| phone | string | ✅ | Contact number |
| bike_model | string | ❌ | Optional vehicle info |
| emergency_contact | string | ✅ | Used during SOS escalation |
| blood_group | string | ❌ | Medical aid |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `rides`
**Purpose:** Ride tracking

| Field | Type | Required | Notes |
|---|---|---|---|
| user_id | string | ✅ | Rider reference |
| start_lat | double | ✅ | Ride start latitude |
| start_lng | double | ✅ | Ride start longitude |
| end_lat | double | ❌ | Ride end latitude |
| end_lng | double | ❌ | Ride end longitude |
| status | string | ✅ | active / completed / emergency |
| crash_detected | boolean | ❌ | Default false |
| avg_speed | double | ❌ | Telemetry |
| max_speed | double | ❌ | Telemetry |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `potholes`
**Purpose:** Crowd-reported road hazards

| Field | Type | Required | Notes |
|---|---|---|---|
| reported_by | string | ✅ | Rider reference |
| lat | double | ✅ | Location |
| lng | double | ✅ | Location |
| severity | string | ❌ | low / medium / high |
| reports_count | integer | ❌ | Default 1 |
| verified | boolean | ❌ | Admin validation |
| last_reported_at | datetime | ❌ | Latest report |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `puncture_shops`
**Purpose:** Rider-added roadside mechanics

| Field | Type | Required | Notes |
|---|---|---|---|
| added_by | string | ✅ | Rider reference |
| lat | double | ✅ | Location |
| lng | double | ✅ | Location |
| shop_name | string | ❌ | Display name |
| is_temporary | boolean | ❌ | Default true |
| verified | boolean | ❌ | Admin approval |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `connectivity_zones`
**Purpose:** Low network heatmap intelligence

| Field | Type | Required | Notes |
|---|---|---|---|
| reported_by | string | ✅ | Rider reference |
| lat | double | ✅ | Location |
| lng | double | ✅ | Location |
| signal_strength | integer | ❌ | Lower means weaker |
| reports_count | integer | ❌ | Default 1 |
| verified | boolean | ❌ | Admin validation |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `alerts`
**Purpose:** Crash detection + manual SOS

| Field | Type | Required | Notes |
|---|---|---|---|
| user_id | string | ✅ | Rider reference |
| ride_id | string | ❌ | Ride reference |
| alert_type | string | ✅ | crash_auto / sos_manual |
| lat | double | ✅ | Location |
| lng | double | ✅ | Location |
| notified_contacts | boolean | ❌ | Default false |
| resolved | boolean | ❌ | Default false |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Table: `mesh_nodes` (Optional Advanced Feature)
**Purpose:** Rider-to-rider mesh detection

| Field | Type | Required | Notes |
|---|---|---|---|
| user_id | string | ✅ | Rider reference |
| lat | double | ❌ | Location |
| lng | double | ❌ | Location |
| is_active | boolean | ❌ | Default true |
| last_ping_at | datetime | ❌ | Health signal |
| $createdAt | datetime | auto | System generated |
| $updatedAt | datetime | auto | System generated |

---

## Notes for Judges & Developers

This schema enables:

- Real-time ride monitoring  
- Emergency escalation  
- Peer-to-peer mesh modeling  
- Crowd intelligence  
- Future smart-city integrations  

The structure is designed for scalability and offline-first synchronization.

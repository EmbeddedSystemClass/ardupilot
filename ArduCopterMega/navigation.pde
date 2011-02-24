// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: t -*-

//****************************************************************
// Function that will calculate the desired direction to fly and distance
//****************************************************************
void navigate()
{
	// do not navigate with corrupt data
	// ---------------------------------
	if (g_gps->fix == 0){
		g_gps->new_data = false;
		return;
	}

	if(next_WP.lat == 0){
		return;
	}

	// waypoint distance from plane
	// ----------------------------
	wp_distance = getDistance(&current_loc, &next_WP);

	if (wp_distance < 0){
		gcs.send_text(SEVERITY_HIGH,"<navigate> WP error - distance < 0");
		//Serial.println(wp_distance,DEC);
		//print_current_waypoints();
		return;
	}

	// target_bearing is where we should be heading
	// --------------------------------------------
	target_bearing 	= get_bearing(&current_loc, &next_WP);

	// nav_bearing will includes xtrac correction
	// ------------------------------------------
	nav_bearing = target_bearing;

	// check if we have missed the WP
	loiter_delta = (target_bearing - old_target_bearing)/100;

	// reset the old value
	old_target_bearing = target_bearing;

	// wrap values
	if (loiter_delta > 180) loiter_delta -= 360;
	if (loiter_delta < -180) loiter_delta += 360;
	loiter_sum += abs(loiter_delta);

	// control mode specific updates to nav_bearing
	// --------------------------------------------
	update_navigation();
}

#define DIST_ERROR_MAX 1800
void calc_nav()
{
	Vector2f yawvector;
	Matrix3f temp;

	/*
	Becuase we are using lat and lon to do our distance errors here's a quick chart:
	100 	= 1m
	1000 	= 11m
	3000 	= 33m
	10000 	= 111m
	pitch_max = 22° (2200)
	*/

	long_error	= (float)(next_WP.lng - current_loc.lng) * scaleLongDown;   // 50 - 30 = 20 pitch right
	lat_error	= next_WP.lat - current_loc.lat;							// 50 - 30 = 20 pitch up

	long_error	= constrain(long_error, -DIST_ERROR_MAX, DIST_ERROR_MAX); // +- 20m max error
	lat_error	= constrain(lat_error,  -DIST_ERROR_MAX, DIST_ERROR_MAX); // +- 20m max error

	// Convert distance into ROLL X
	nav_lon		= long_error * g.pid_nav_lon.kP();						// 1800 * 2 = 3600 or 36°
	//nav_lon	= g.pid_nav_lon.get_pid(long_error, dTnav2, 1.0);
	//nav_lon 	= constrain(nav_lon, -DIST_ERROR_MAX, DIST_ERROR_MAX); // Limit max command

	// PITCH	Y
	//nav_lat 	= g.pid_nav_lat.get_pid(lat_error, dTnav2, 1.0);
	nav_lat		= lat_error * g.pid_nav_lat.kP();							// 1800 * 2 = 3600 or 36°
	//nav_lat 	= constrain(nav_lat, -DIST_ERROR_MAX, DIST_ERROR_MAX); // Limit max command

	// rotate the vector
	nav_roll 	= (float)nav_lon * sin_yaw_y - (float)nav_lat * cos_yaw_x;
	nav_pitch 	= -((float)nav_lon * cos_yaw_x + (float)nav_lat * sin_yaw_y);

	nav_roll 	= constrain(nav_roll,  -g.pitch_max.get(), g.pitch_max.get());
	nav_pitch 	= constrain(nav_pitch, -g.pitch_max.get(), g.pitch_max.get());
}

void calc_bearing_error()
{
	bearing_error 	= nav_bearing - dcm.yaw_sensor;
	bearing_error 	= wrap_180(bearing_error);
}

void calc_altitude_error()
{
	if(control_mode == AUTO && offset_altitude != 0) {
		// limit climb rates - we draw a straight line between first location and edge of waypoint_radius
		target_altitude = next_WP.alt - ((wp_distance * offset_altitude) / (wp_totalDistance - g.waypoint_radius));

		// stay within a certain range
		if(prev_WP.alt > next_WP.alt){
			target_altitude = constrain(target_altitude, next_WP.alt, prev_WP.alt);
		}else{
			target_altitude = constrain(target_altitude, prev_WP.alt, next_WP.alt);
		}
	}else{
		target_altitude = next_WP.alt;
	}

	altitude_error 	= target_altitude - current_loc.alt;
}

long wrap_360(long error)
{
	if (error > 36000)	error -= 36000;
	if (error < 0)		error += 36000;
	return error;
}

long wrap_180(long error)
{
	if (error > 18000)	error -= 36000;
	if (error < -18000)	error += 36000;
	return error;
}

void update_loiter()
{
	float power;

	if(wp_distance <= g.loiter_radius){
		power = float(wp_distance) / float(g.loiter_radius);
		nav_bearing += (int)(9000.0 * (2.0 + power));

	}else if(wp_distance < (g.loiter_radius + LOITER_RANGE)){
		power = -((float)(wp_distance - g.loiter_radius - LOITER_RANGE) / LOITER_RANGE);
		power = constrain(power, 0, 1);
		nav_bearing -= power * 9000;

	}else{
		update_crosstrack();
		loiter_time = millis();			// keep start time for loiter updating till we get within LOITER_RANGE of orbit
	}

	if (wp_distance < g.loiter_radius){
		nav_bearing += 9000;
	}else{
		nav_bearing -= 100 * M_PI / 180 * asin(g.loiter_radius / wp_distance);
	}

	update_crosstrack;
	nav_bearing = wrap_360(nav_bearing);
}

void update_crosstrack(void)
{
	// Crosstrack Error
	// ----------------
	if (abs(target_bearing - crosstrack_bearing) < 4500) {	 // If we are too far off or too close we don't do track following
		crosstrack_error = sin(radians((target_bearing - crosstrack_bearing) / 100)) * wp_distance;	 // Meters we are off track line
		nav_bearing += constrain(crosstrack_error * g.crosstrack_gain, -g.crosstrack_entry_angle.get(), g.crosstrack_entry_angle.get());
		nav_bearing = wrap_360(nav_bearing);
	}
}

void reset_crosstrack()
{
	crosstrack_bearing 	= get_bearing(&current_loc, &next_WP);	// Used for track following
}

long get_altitude_above_home(void)
{
	// This is the altitude above the home location
	// The GPS gives us altitude at Sea Level
	// if you slope soar, you should see a negative number sometimes
	// -------------------------------------------------------------
	return current_loc.alt - home.alt;
}

long getDistance(struct Location *loc1, struct Location *loc2)
{
	if(loc1->lat == 0 || loc1->lng == 0)
		return -1;
	if(loc2->lat == 0 || loc2->lng == 0)
		return -1;
	float dlat 		= (float)(loc2->lat - loc1->lat);
	float dlong		= ((float)(loc2->lng - loc1->lng)) * scaleLongDown;
	return sqrt(sq(dlat) + sq(dlong)) * .01113195;
}

long get_alt_distance(struct Location *loc1, struct Location *loc2)
{
	return abs(loc1->alt - loc2->alt);
}

long get_bearing(struct Location *loc1, struct Location *loc2)
{
	long off_x = loc2->lng - loc1->lng;
	long off_y = (loc2->lat - loc1->lat) * scaleLongUp;
	long bearing =	9000 + atan2(-off_y, off_x) * 5729.57795;
	if (bearing < 0) bearing += 36000;
	return bearing;
}

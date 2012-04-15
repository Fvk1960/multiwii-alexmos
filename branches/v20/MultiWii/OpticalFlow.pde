/* Optical flow sensor reading and calculations */
/* (c) alexmos 2012 */
#ifdef OPTFLOW

/* attempt to fasten SPI read-write */
#if !defined(digitalWriteFast)
	#include "digitalWriteFast.h"
#endif


static uint16_t scale; // scale factor for raw sensor data
static int16_t sum_dx = 0, sum_dy = 0; // sensor's row data accumulators
static int16_t EstHVel[2] = { 0, 0 };  // horisontal velocity, cm/sec (constrained -100, 100)
static int16_t optflow_pos[2] = { 0, 0 }; // displacment (in mm*10 on height 1m)






/* PID calculations. Outputs optflow_angle[ROLL], optflow_angle[PITCH] */
inline void Optflow_update() {
	static int16_t optflowErrorI[2] = { 0, 0 };
	static int16_t prevHeading = 0;
	static int8_t optflowUse = 0;
	int8_t axis;
	
  // enable OPTFLOW only in LEVEL mode and if GPS is not used
  if(accMode == 1 && optflowMode == 1 && GPSModeHome == 0) {
		// init first time mode enabled
		if(!optflowUse) {
	  	optflowErrorI[0] = 0;	optflowErrorI[1] = 0;
			prevHeading = heading;
			optflowUse = 1;
		}
		
		// Read sensors
		optflow_read();

		// Rotate I to follow global axis
		#ifdef OF_ROTATE_I
      int16_t dif = heading - prevHeading;
      if (dif <= - 180) dif += 360;
      else if (dif >= + 180) dif -= 360;

			if(abs(dif) > 5) { // rotate by 5-degree steps
				rotate16(optflowErrorI, dif*10);
				prevHeading = heading;
			}
		#endif

		// Use sensor only inside DEADBAND
		if(abs(rcCommand[ROLL]) < OF_DEADBAND && abs(rcCommand[PITCH]) < OF_DEADBAND) {
			// calculate velocity
			optflow_get_vel();

	  	for(axis=0; axis<2; axis++) {
	  		// correction should be less near deadband limits
  			EstHVel[axis] = EstHVel[axis] * (OF_DEADBAND - abs(rcCommand[axis])) / OF_DEADBAND; // 16 bit ok: 100*100 = 10000
		  	
	  		optflowErrorI[axis]+= EstHVel[axis]; 
	  		optflowErrorI[axis] = constrain(optflowErrorI[axis], -20000, 20000);

	  		optflow_angle[axis] = EstHVel[axis] * P8[PIDVEL] / 50;  // 16 bit ok: 100 * 200 = 20000
			}		  		
  	} else {
  		optflow_angle[0] = 0;	optflow_angle[1] = 0;
  	}

		// Apply I-term unconditionally
  	for(axis=0; axis<2; axis++) {
			optflow_angle[axis] = constrain(optflow_angle[axis] + (int16_t)((int32_t)optflowErrorI[axis] * I8[PIDVEL] / 5000),
				-300, 300);
		}

  	#ifdef OF_DEBUG
  		debug4 = optflow_angle[0]*10;
  	#endif
  } else if(optflowUse) { // switch mode off
  	optflow_angle[0] = 0; optflow_angle[1] = 0;
  	optflowUse = 0;
  }
}


/* Calculate estimated velocity from OF-sensor */
inline void optflow_get_vel() {
	int16_t vel_of[2]; // velocity from OF-sensor, cm/sec
	static int16_t prevAngle[2] = { 0, 0 };
	static t_avg_var16 avgVel[2] = { {0,0}, {0,0} }; 
	static t_avg_var8 avgSqual = {0,0};
	uint16_t alt; // alt in mm*10
	int8_t axis;

	static uint16_t prevTime = 0;
	uint16_t tmpTime = micros();
	uint16_t dTime = tmpTime - prevTime;
	prevTime = tmpTime;
	
	// get normalized sensor values
	optflow_get();
	
	// read and average surface quality
	average8(&avgSqual, (int8_t)optflow_squal(), 5);

	if(cosZ > 70 && avgSqual.res > 10) {
		// above 3m, freeze altitude (it means less stabilization on high altitude)
 		// .. and reduce signal if surface quality <50
		alt = constrain((int16_t)EstAlt, 30, 300) * min(avgSqual.res,50) * 2; // 16 bit ok: 300 * 50 * 2 = 30000;
	} else {
		alt = 0;
	}
	
	for(axis=0;axis<2;axis++) {
		// Get velocity from OF-sensor only in good conditions
		if(alt != 0) { 
			// remove shift in position due to inclination: delta_angle * PI / 180 * 100
			// mm/sec(10m) * cm / us   ->    cm / sec
			vel_of[axis] = ((int32_t)optflow_pos[axis] + (angle[axis] - prevAngle[axis]) * 17 ) * alt / dTime ; 
		} else {
			vel_of[axis] = 0;
		}
		
 		average16(&avgVel[axis], vel_of[axis], OF_LPF_FACTOR);
		EstHVel[axis] = constrain(avgVel[axis].res, -100, 100);
		prevAngle[axis] = angle[axis];
	}
	
	#ifdef OF_DEBUG
		debug2 = optflow_pos[0];
		debug3 = avgSqual.res;
		//debug4 = vel_of[0]*10;
	#endif
}



/* Convert row data to displacment (in mm*10 on height 1m)  since last call */
inline void optflow_get() {
	optflow_pos[1] = constrain((int32_t)sum_dx * scale, -0x7FFF, 0x7FFF);
	optflow_pos[0] = constrain((int32_t)sum_dy * scale, -0x7FFF, 0x7FFF);

	// clear accumulated displacement
	sum_dx = 0; sum_dy = 0; 
}	








/* *************************************************** */
/* Configuration and routines for each sensor          */
#if(OPTFLOW==ADNS_5050)
	#define PRODUCT_ID          0x00 // should be 0x12
	#define PRODUCTID2          0x3e
	#define REVISION_ID         0x01
	#define MOTION_REG					0x02
	#define DELTA_Y_REG         0x03
	#define DELTA_X_REG         0x04
	#define SQUAL_REG           0x05
	#define MAXIMUM_PIXEL_REG   0x08
	#define MINIMUM_PIXEL_REG   0x0a
	#define PIXEL_SUM_REG       0x09
	#define PIXEL_DATA_REG      0x0b
	#define SHUTTER_UPPER_REG   0x06
	#define SHUTTER_LOWER_REG   0x07
	#define RESET		    0x3a
	#define MOUSE_CONTROL	0x0d
	#define MOUSE_CONTROL2 0x19

	// resolution
	//#define RES_CPI 	250
	//	#define RES_CFG 	0b10010
	//#define RES_CPI 	500
	//	#define RES_CFG 	0b10100
	//#define RES_CPI 	750
	//	#define RES_CFG 	0b10110
	//#define RES_CPI		1000 	
	//	#define RES_CFG		0b11000
	#define RES_CPI		1250
		#define RES_CFG	0b11010


inline void initOptflow() {
  pinModeFast(OF_SDIO, OUTPUT);
  pinModeFast(OF_SCLK, OUTPUT);
  pinModeFast(OF_NCS, OUTPUT);

  // reset device
  ADNS_write(RESET, 0x5a);
  delayMicroseconds(50);
  
  scale = (uint32_t)500000 / OF_FOCAL_DIST / RES_CPI;
  
  if(ADNS_read(PRODUCT_ID) == 0x12) {
 		ADNS_write(MOUSE_CONTROL2, RES_CPI); // Set resolution
  }
}

/* Read sensor values. Should be called in every main loop to prevent sensor's internal counters overflow */
inline void optflow_read() {
  if(ADNS_read(MOTION_REG) != 0) {
  	sum_dx+= (int8_t)ADNS_read(DELTA_X_REG);
  	sum_dy+= (int8_t)ADNS_read(DELTA_Y_REG);
  }
}

/* get surface quality, (0..127) */
inline uint8_t optflow_squal() {
	return ADNS_read(SQUAL_REG);
}

/* Write byte of data to SPI */
void _spi_write(byte val) {
  for (byte i=128; i >0 ; i >>= 1) {
    digitalWriteFast (OF_SCLK, LOW);
    digitalWriteFast (OF_SDIO, (val & i) != 0 ? HIGH : LOW);
    delayMicroseconds(1);
    digitalWriteFast (OF_SCLK, HIGH);
  }
}	

/* Read register */
byte ADNS_read(byte address) {
  digitalWriteFast(OF_NCS, LOW);// select the chip
  delayMicroseconds(1);

  pinModeFast (OF_SDIO, OUTPUT);
  _spi_write(address);

  delayMicroseconds(4); // tSRAD = 4us min.

  pinModeFast (OF_SDIO, INPUT);
  byte res = 0;
  for (byte i=128; i >0 ; i >>= 1) {
    digitalWriteFast (OF_SCLK, LOW);
    delayMicroseconds(1);
    digitalWriteFast (OF_SCLK, HIGH);
    if( digitalReadFast (OF_SDIO) == HIGH )
      res |= i;
  }

  digitalWriteFast(OF_NCS, HIGH);// de-select the chip
  return res;
}

/* Write register */
void ADNS_write(byte address, byte data) {
  digitalWriteFast(OF_NCS, LOW);// select the chip
  delayMicroseconds(1);

  pinModeFast (OF_SDIO, OUTPUT);
  _spi_write(address);
  _spi_write(data);

  digitalWriteFast(OF_NCS, HIGH);// de-select the chip
}


#endif



#endif
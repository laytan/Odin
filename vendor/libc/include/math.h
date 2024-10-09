#include <stdbool.h>

#define INFINITY (1.0 / 0.0)
#define NAN      (0.0 / 0.0)

float sqrtf(float);
float cosf(float);
float sinf(float);
float atan2f(float, float);
bool isnan(float);
bool isinf(float);
double floor(double x);
double ceil(double x);
double sqrt(double x);
double pow(double x, double y);
double fmod(double x, double y);
double cos(double x);
double acos(double x);
double fabs(double x);
int abs(int);
double ldexp(double, int);
double exp(double);
float log(float);
float sin(float);
double trunc(double);
bool isfinite(float);

double log2(double);
double log10(double);
double asin(double);
double atan(double);
double tan(double);
double atan2(double, double);
double modf(double, double*);
